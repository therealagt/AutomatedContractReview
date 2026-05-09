package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"cloud.google.com/go/storage"
	"github.com/therealagt/automatedcontractreview/services/contracts"
)

type app struct {
	firestore *firestore.Client
	storage   *storage.Client
	bucket    string
}

type finalizeRequest struct {
	JobID       string            `json:"jobId"`
	Source      contracts.Source  `json:"source"`
	AnalysisRef string            `json:"analysisRef"`
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
	procBucket := os.Getenv("PROCESSED_BUCKET")
	if projectID == "" || procBucket == "" {
		slog.Error("missing PROJECT_ID or PROCESSED_BUCKET")
		os.Exit(1)
	}

	ctx := context.Background()
	fs, err := firestore.NewClient(ctx, projectID)
	if err != nil {
		slog.Error("firestore client", "error", err)
		os.Exit(1)
	}
	defer fs.Close()

	st, err := storage.NewClient(ctx)
	if err != nil {
		slog.Error("storage client", "error", err)
		os.Exit(1)
	}
	defer st.Close()

	application := &app{firestore: fs, storage: st, bucket: procBucket}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/", application.finalizeHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	slog.Info("finalize listening", "port", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *app) finalizeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req finalizeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if req.JobID == "" || req.Source.Bucket == "" || req.Source.Object == "" || req.AnalysisRef == "" {
		http.Error(w, "invalid payload", http.StatusBadRequest)
		return
	}
	if !strings.HasPrefix(req.AnalysisRef, "gs://") {
		http.Error(w, "invalid analysisRef", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
	defer cancel()

	current, err := a.getCurrentStatus(ctx, req.JobID)
	if err != nil {
		slog.Error("read status", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "status read failed", http.StatusServiceUnavailable)
		return
	}
	if current != contracts.StatusAnalyzed && current != contracts.StatusRedacted {
		slog.Warn("unexpected status for finalize", "jobId", req.JobID, "status", current)
		http.Error(w, "invalid status transition", http.StatusConflict)
		return
	}

	baseName := path.Base(req.Source.Object)
	if baseName == "" || baseName == "." || baseName == "/" {
		baseName = "document.pdf"
	}
	destKey := "final/" + req.JobID + "/" + baseName

	src := a.storage.Bucket(req.Source.Bucket).Object(req.Source.Object)
	if req.Source.Generation != "" {
		if g, err := strconv.ParseUint(req.Source.Generation, 10, 64); err == nil {
			src = src.Generation(int64(g))
		}
	}

	dst := a.storage.Bucket(a.bucket).Object(destKey)
	if _, err := dst.CopierFrom(src).Run(ctx); err != nil {
		slog.Error("copy source pdf", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "copy failed", http.StatusBadGateway)
		return
	}

	outputURI := "gs://" + a.bucket + "/final/" + req.JobID + "/"
	now := time.Now().UTC().Format(time.RFC3339Nano)
	update := map[string]any{
		"status":             contracts.StatusFinalized,
		"schemaVersion":      contracts.SchemaVersion,
		"finalizedAt":        now,
		"finalizeResult": map[string]any{
			"outputUri":    outputURI,
			"pdfObject":    destKey,
			"analysisRef":  strings.TrimSuffix(req.AnalysisRef, "/"),
		},
	}
	if _, err := a.firestore.Collection("contractJobs").Doc(req.JobID).Set(ctx, update, firestore.MergeAll); err != nil {
		slog.Error("firestore finalize", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "status update failed", http.StatusServiceUnavailable)
		return
	}

	slog.Info("finalized", "jobId", req.JobID, "outputUri", outputURI)
	writeJSON(w, http.StatusOK, map[string]any{
		"jobId":     req.JobID,
		"status":    contracts.StatusFinalized,
		"outputUri": outputURI,
	})
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
	s, ok := status.(string)
	if !ok || s == "" {
		return "", errors.New("missing status")
	}
	return s, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "error", err)
	}
}
