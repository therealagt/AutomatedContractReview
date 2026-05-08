package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"

	"cloud.google.com/go/firestore"
	"github.com/therealagt/automatedcontractreview/services/contracts"
)

type app struct {
	firestore       *firestore.Client
	processedBucket string
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
	if projectID == "" {
		slog.Error("missing required env var PROJECT_ID")
		os.Exit(1)
	}
	processedBucket := os.Getenv("PROCESSED_BUCKET")
	if processedBucket == "" {
		slog.Error("missing required env var PROCESSED_BUCKET")
		os.Exit(1)
	}

	firestoreCli, err := firestore.NewClient(context.Background(), projectID)
	if err != nil {
		slog.Error("create firestore client", "error", err)
		os.Exit(1)
	}
	defer firestoreCli.Close()

	application := &app{
		firestore:       firestoreCli,
		processedBucket: processedBucket,
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
		Handler:           mux,
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

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	currentStatus, err := a.getCurrentStatus(ctx, msg.JobID)
	if err != nil {
		slog.Error("read current status failed", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "status read failed", http.StatusServiceUnavailable)
		return
	}

	if err := contracts.CanTransition(currentStatus, contracts.StatusDocAIDone); err != nil {
		slog.Warn("invalid status transition", "jobId", msg.JobID, "from", currentStatus, "to", contracts.StatusDocAIDone, "error", err.Error())
		http.Error(w, "invalid status transition", http.StatusConflict)
		return
	}

	extractedTextRef := "gs://" + a.processedBucket + "/extracted/" + msg.JobID + "/"
	update := map[string]any{
		"status":           contracts.StatusDocAIDone,
		"schemaVersion":    contracts.SchemaVersion,
		"docaiCompletedAt": time.Now().UTC().Format(time.RFC3339Nano),
		"docaiResult": map[string]any{
			"extractedTextRef": extractedTextRef,
		},
	}
	if _, err := a.firestore.Collection("contractJobs").Doc(msg.JobID).Set(ctx, update, firestore.MergeAll); err != nil {
		slog.Error("status update failed", "jobId", msg.JobID, "error", err.Error())
		http.Error(w, "status update failed", http.StatusServiceUnavailable)
		return
	}

	slog.Info("docai stage completed", "jobId", msg.JobID, "status", contracts.StatusDocAIDone, "extractedTextRef", extractedTextRef)
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
