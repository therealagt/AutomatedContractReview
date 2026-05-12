package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	dlp "cloud.google.com/go/dlp/apiv2"
	"cloud.google.com/go/dlp/apiv2/dlppb"
	"cloud.google.com/go/firestore"
	"cloud.google.com/go/storage"
	"github.com/therealagt/automatedcontractreview/services/contracts"
	"google.golang.org/api/iterator"
)

type app struct {
	firestore          *firestore.Client
	storage            *storage.Client
	dlp                *dlp.Client
	projectID          string
	inspectTemplate    string
	deidentifyTemplate string
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		ReplaceAttr: func(_ []string, a slog.Attr) slog.Attr {
			switch a.Key {
			case slog.MessageKey:
				a.Key = "message"
			case slog.LevelKey:
				a.Key = "severity"
			}
			return a
		},
	})))

	projectID := os.Getenv("PROJECT_ID")
	inspectTmpl := os.Getenv("DLP_INSPECT_TMPL")
	deidentifyTmpl := os.Getenv("DLP_DEIDENTIFY_TMPL")
	if projectID == "" || inspectTmpl == "" || deidentifyTmpl == "" {
		slog.Error("missing required env vars PROJECT_ID, DLP_INSPECT_TMPL, or DLP_DEIDENTIFY_TMPL")
		os.Exit(1)
	}

	ctx := context.Background()
	fsCli, err := firestore.NewClient(ctx, projectID)
	if err != nil {
		slog.Error("create firestore client", "error", err)
		os.Exit(1)
	}
	defer fsCli.Close()

	stCli, err := storage.NewClient(ctx)
	if err != nil {
		slog.Error("create storage client", "error", err)
		os.Exit(1)
	}
	defer stCli.Close()

	dlpCli, err := dlp.NewClient(ctx)
	if err != nil {
		slog.Error("create dlp client", "error", err)
		os.Exit(1)
	}
	defer dlpCli.Close()

	application := &app{
		firestore:          fsCli,
		storage:            stCli,
		dlp:                dlpCli,
		projectID:          projectID,
		inspectTemplate:    inspectTmpl,
		deidentifyTemplate: deidentifyTmpl,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/", application.redactHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           contracts.TraceLoggingMiddleware(projectID)(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	slog.Info("pii-redaction listening", "port", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type redactRequest struct {
	JobID              string `json:"jobId"`
	ExtractedTextRef   string `json:"extractedTextRef"`
}

func (a *app) redactHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req redactRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if req.JobID == "" || req.ExtractedTextRef == "" || !strings.HasPrefix(req.ExtractedTextRef, "gs://") {
		http.Error(w, "invalid payload", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Minute)
	defer cancel()

	log := contracts.RequestLogger(ctx)

	currentStatus, err := a.getCurrentStatus(ctx, req.JobID)
	if err != nil {
		log.Error("read current status failed", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "status read failed", http.StatusServiceUnavailable)
		return
	}

	if err := contracts.CanTransition(currentStatus, contracts.StatusRedacted); err != nil {
		log.Warn("invalid status transition", "jobId", req.JobID, "from", currentStatus, "to", contracts.StatusRedacted, "error", err.Error())
		http.Error(w, "invalid status transition", http.StatusConflict)
		return
	}

	bucket, prefix, err := parseGCSURI(req.ExtractedTextRef)
	if err != nil {
		http.Error(w, "bad extractedTextRef", http.StatusBadRequest)
		return
	}

	raw, objectName, err := readFirstObjectBytes(ctx, a.storage, bucket, prefix)
	if err != nil {
		log.Error("read extracted object failed", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "read extracted content failed", http.StatusBadGateway)
		return
	}

	text := normalizeExtractedText(raw, objectName)
	parent := fmt.Sprintf("projects/%s/locations/global", a.projectID)
	dlpReq := &dlppb.DeidentifyContentRequest{
		Parent:                 parent,
		InspectTemplateName:    a.inspectTemplate,
		DeidentifyTemplateName:  a.deidentifyTemplate,
		Item: &dlppb.ContentItem{
			DataItem: &dlppb.ContentItem_Value{Value: text},
		},
	}

	dlpResp, err := a.dlp.DeidentifyContent(ctx, dlpReq)
	if err != nil {
		log.Error("dlp deidentify failed", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "dlp deidentify failed", http.StatusBadGateway)
		return
	}

	item := dlpResp.GetItem()
	if item == nil {
		log.Error("dlp empty item", "jobId", req.JobID)
		http.Error(w, "dlp empty response", http.StatusBadGateway)
		return
	}
	redacted := item.GetValue()
	outObject := fmt.Sprintf("redacted/%s/redacted.txt", req.JobID)
	redactedRef := fmt.Sprintf("gs://%s/%s", bucket, outObject)
	if err := writeObject(ctx, a.storage, bucket, outObject, []byte(redacted)); err != nil {
		log.Error("write redacted object failed", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "write redacted output failed", http.StatusBadGateway)
		return
	}

	now := time.Now().UTC().Format(time.RFC3339Nano)
	update := map[string]any{
		"status":              contracts.StatusRedacted,
		"schemaVersion":       contracts.SchemaVersion,
		"redactionCompletedAt": now,
		"redactionResult": map[string]any{
			"redactedTextRef":    redactedRef,
			"redactedTextLength": len([]rune(redacted)),
			"sourceObject":       objectName,
		},
	}
	if _, err := a.firestore.Collection("contractJobs").Doc(req.JobID).Set(ctx, update, firestore.MergeAll); err != nil {
		log.Error("status update failed", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "status update failed", http.StatusServiceUnavailable)
		return
	}

	log.Info("redaction completed", "jobId", req.JobID, "redactedTextRef", redactedRef, "redactedTextLength", len([]rune(redacted)))
	writeJSON(w, http.StatusOK, map[string]any{
		"jobId":              req.JobID,
		"status":             contracts.StatusRedacted,
		"redactedTextRef":    redactedRef,
		"redactedTextLength": len([]rune(redacted)),
	})
}

func parseGCSURI(uri string) (bucket, prefix string, err error) {
	const pfx = "gs://"
	if !strings.HasPrefix(uri, pfx) {
		return "", "", errors.New("not a gs:// uri")
	}
	rest := strings.TrimPrefix(uri, pfx)
	idx := strings.IndexByte(rest, '/')
	if idx < 0 {
		return rest, "", nil
	}
	return rest[:idx], rest[idx+1:], nil
}

func readFirstObjectBytes(ctx context.Context, client *storage.Client, bucket, prefix string) ([]byte, string, error) {
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		r, err := client.Bucket(bucket).Object(prefix).NewReader(ctx)
		if err == nil {
			defer r.Close()
			data, err := io.ReadAll(r)
			return data, prefix, err
		}
		if !errors.Is(err, storage.ErrObjectNotExist) {
			return nil, "", err
		}
	}
	p := prefix
	if p != "" && !strings.HasSuffix(p, "/") {
		p += "/"
	}
	it := client.Bucket(bucket).Objects(ctx, &storage.Query{Prefix: p})
	var chosenName string
	for {
		attrs, err := it.Next()
		if errors.Is(err, iterator.Done) {
			break
		}
		if err != nil {
			return nil, "", err
		}
		if strings.HasSuffix(attrs.Name, "/") {
			continue
		}
		if chosenName == "" || attrs.Name < chosenName {
			chosenName = attrs.Name
		}
	}
	if chosenName == "" {
		return nil, "", fmt.Errorf("no objects under gs://%s/%s", bucket, p)
	}
	r, err := client.Bucket(bucket).Object(chosenName).NewReader(ctx)
	if err != nil {
		return nil, "", err
	}
	defer r.Close()
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, "", err
	}
	return data, chosenName, nil
}

func writeObject(ctx context.Context, client *storage.Client, bucket, name string, data []byte) error {
	w := client.Bucket(bucket).Object(name).NewWriter(ctx)
	w.ContentType = "text/plain; charset=utf-8"
	if _, err := io.Copy(w, bytes.NewReader(data)); err != nil {
		_ = w.Close()
		return err
	}
	return w.Close()
}

func normalizeExtractedText(raw []byte, objectName string) string {
	s := string(raw)
	if strings.HasSuffix(strings.ToLower(objectName), ".json") {
		var doc struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(raw, &doc); err == nil && doc.Text != "" {
			return doc.Text
		}
	}
	return s
}

func (a *app) getCurrentStatus(ctx context.Context, jobID string) (string, error) {
	snap, err := a.firestore.Collection("contractJobs").Doc(jobID).Get(ctx)
	if err != nil {
		return "", err
	}
	status, err := snap.DataAt("status")
	if err != nil {
		return "", err
	}
	statusText, ok := status.(string)
	if !ok || statusText == "" {
		return "", errors.New("missing status field")
	}
	return statusText, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "error", err)
	}
}
