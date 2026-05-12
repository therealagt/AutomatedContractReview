package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	documentai "cloud.google.com/go/documentai/apiv1"
	"cloud.google.com/go/documentai/apiv1/documentaipb"
	"cloud.google.com/go/firestore"
	"cloud.google.com/go/storage"
	"github.com/therealagt/automatedcontractreview/services/contracts"
	"google.golang.org/api/option"
)

type app struct {
	firestore       *firestore.Client
	storage         *storage.Client
	docai           *documentai.DocumentProcessorClient
	processorName   string
	processedBucket string
	handlerTimeout  time.Duration
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
	processorName := os.Getenv("DOCAI_PROCESSOR_NAME")
	docaiLocation := os.Getenv("DOCAI_LOCATION")
	processedBucket := os.Getenv("PROCESSED_BUCKET")
	if projectID == "" || processorName == "" || docaiLocation == "" || processedBucket == "" {
		slog.Error("missing required env vars PROJECT_ID, DOCAI_PROCESSOR_NAME, DOCAI_LOCATION, or PROCESSED_BUCKET")
		os.Exit(1)
	}

	handlerTimeout := 1700 * time.Second
	if v := os.Getenv("HANDLER_TIMEOUT_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			handlerTimeout = time.Duration(n) * time.Second
		}
	}

	ctx := context.Background()
	firestoreCli, err := firestore.NewClient(ctx, projectID)
	if err != nil {
		slog.Error("create firestore client", "error", err)
		os.Exit(1)
	}
	defer firestoreCli.Close()

	stCli, err := storage.NewClient(ctx)
	if err != nil {
		slog.Error("create storage client", "error", err)
		os.Exit(1)
	}
	defer stCli.Close()

	endpoint := fmt.Sprintf("%s-documentai.googleapis.com:443", docaiLocation)
	docaiCli, err := documentai.NewDocumentProcessorClient(ctx, option.WithEndpoint(endpoint))
	if err != nil {
		slog.Error("create documentai client", "error", err)
		os.Exit(1)
	}
	defer docaiCli.Close()

	application := &app{
		firestore:       firestoreCli,
		storage:         stCli,
		docai:           docaiCli,
		processorName:   processorName,
		processedBucket: processedBucket,
		handlerTimeout:  handlerTimeout,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/extract", application.extractHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           contracts.TraceLoggingMiddleware(projectID)(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	slog.Info("docai service listening", "port", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *app) extractHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var msg contracts.JobMessage
	if err := json.NewDecoder(r.Body).Decode(&msg); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}

	if msg.SchemaVersion == "" {
		msg.SchemaVersion = contracts.SchemaVersion
	}
	if msg.JobID == "" || msg.Source.Bucket == "" || msg.Source.Object == "" {
		http.Error(w, "invalid payload", http.StatusBadRequest)
		return
	}

	log := contracts.RequestLogger(r.Context())

	ctx, cancel := context.WithTimeout(r.Context(), a.handlerTimeout)
	defer cancel()

	currentStatus, err := a.getCurrentStatus(ctx, msg.JobID)
	if err != nil {
		log.Error("read current status failed", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "status read failed", http.StatusServiceUnavailable)
		return
	}

	if err := contracts.CanTransition(currentStatus, contracts.StatusDocAIDone); err != nil {
		log.Warn("invalid status transition", "jobId", msg.JobID, "from", currentStatus, "to", contracts.StatusDocAIDone, "error", err.Error())
		http.Error(w, "invalid status transition", http.StatusConflict)
		return
	}

	gcsURI := fmt.Sprintf("gs://%s/%s", msg.Source.Bucket, msg.Source.Object)
	if msg.Source.Generation != "" {
		gcsURI = gcsURI + "#" + msg.Source.Generation
	}

	dresp, err := a.docai.ProcessDocument(ctx, &documentaipb.ProcessRequest{
		Name: a.processorName,
		Source: &documentaipb.ProcessRequest_GcsDocument{
			GcsDocument: &documentaipb.GcsDocument{
				MimeType: "application/pdf",
				GcsUri:   gcsURI,
			},
		},
		SkipHumanReview: true,
	})
	if err != nil {
		log.Error("documentai process failed", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "document processing failed", http.StatusBadGateway)
		return
	}

	doc := dresp.GetDocument()
	if doc == nil {
		log.Error("documentai empty document", "jobId", msg.JobID)
		http.Error(w, "empty document result", http.StatusBadGateway)
		return
	}

	text := doc.GetText()
	if text == "" {
		log.Error("documentai empty text", "jobId", msg.JobID)
		http.Error(w, "no extractable text", http.StatusBadGateway)
		return
	}

	outObject := fmt.Sprintf("extracted/%s/extracted.json", msg.JobID)
	payload, err := json.Marshal(map[string]string{"text": text})
	if err != nil {
		log.Error("marshal extracted json", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	wr := a.storage.Bucket(a.processedBucket).Object(outObject).NewWriter(ctx)
	wr.ContentType = "application/json"
	if _, err := wr.Write(payload); err != nil {
		_ = wr.Close()
		log.Error("write extracted object", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "write extract failed", http.StatusBadGateway)
		return
	}
	if err := wr.Close(); err != nil {
		log.Error("close extracted writer", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "write extract failed", http.StatusBadGateway)
		return
	}

	extractedTextRef := "gs://" + a.processedBucket + "/extracted/" + msg.JobID + "/"
	update := map[string]any{
		"status":           contracts.StatusDocAIDone,
		"schemaVersion":    contracts.SchemaVersion,
		"docaiCompletedAt": time.Now().UTC().Format(time.RFC3339Nano),
		"docaiResult": map[string]any{
			"extractedTextRef": extractedTextRef,
			"extractedObject":  outObject,
		},
	}
	if _, err := a.firestore.Collection("contractJobs").Doc(msg.JobID).Set(ctx, update, firestore.MergeAll); err != nil {
		log.Error("status update failed", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "status update failed", http.StatusServiceUnavailable)
		return
	}

	log.Info("docai stage completed", "jobId", msg.JobID, "status", contracts.StatusDocAIDone, "extractedTextRef", extractedTextRef)
	writeJSON(w, http.StatusOK, map[string]any{
		"jobId":            msg.JobID,
		"status":           contracts.StatusDocAIDone,
		"extractedTextRef": extractedTextRef,
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
