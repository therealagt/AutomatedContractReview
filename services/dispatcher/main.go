package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"time"

	executions "cloud.google.com/go/workflows/executions/apiv1"
	executionspb "cloud.google.com/go/workflows/executions/apiv1/executionspb"
	"github.com/therealagt/automatedcontractreview/services/contracts"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type pubsubEnvelope struct {
	Message struct {
		Data string `json:"data"`
	} `json:"message"`
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
	workflowID := os.Getenv("WORKFLOW_ID")
	if projectID == "" || workflowID == "" {
		slog.Error("missing required env vars PROJECT_ID or WORKFLOW_ID")
		os.Exit(1)
	}

	ctx := context.Background()
	client, err := executions.NewClient(ctx)
	if err != nil {
		slog.Error("create executions client", "error", err)
		os.Exit(1)
	}
	defer client.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/dispatch", dispatchHandler(client, workflowID))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           contracts.TraceLoggingMiddleware(projectID)(mux),
		ReadHeaderTimeout: 10 * time.Second,
	}

	slog.Info("dispatcher listening", "port", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func dispatchHandler(client *executions.Client, workflowID string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var envelope pubsubEnvelope
		if err := json.NewDecoder(r.Body).Decode(&envelope); err != nil {
			http.Error(w, "invalid json body", http.StatusBadRequest)
			return
		}

		if envelope.Message.Data == "" {
			http.Error(w, "empty message", http.StatusBadRequest)
			return
		}

		decoded, err := base64.StdEncoding.DecodeString(envelope.Message.Data)
		if err != nil {
			http.Error(w, "bad payload", http.StatusBadRequest)
			return
		}

		msg, err := contracts.ParseJobMessage(decoded)
		if err != nil {
			http.Error(w, "bad payload", http.StatusBadRequest)
			return
		}

		argument, err := json.Marshal(msg)
		if err != nil {
			http.Error(w, "invalid payload", http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		log := contracts.RequestLogger(ctx)

		resp, err := client.CreateExecution(ctx, &executionspb.CreateExecutionRequest{
			Parent: workflowID,
			Execution: &executionspb.Execution{
				Argument: string(argument),
			},
		})
		if err != nil {
			st, ok := status.FromError(err)
			if ok && st.Code() == codes.ResourceExhausted {
				log.Warn("workflows quota hit, client should retry", "jobId", msg.JobID, "error", err.Error())
				http.Error(w, "workflows quota", http.StatusTooManyRequests)
				return
			}

			log.Error("workflow start failed", "jobId", msg.JobID, "error", err.Error())
			http.Error(w, "workflow start failed", http.StatusServiceUnavailable)
			return
		}

		execName := resp.GetName()
		log.Info("workflow execution started", "jobId", msg.JobID, "executionName", execName)
		writeJSON(w, http.StatusAccepted, map[string]string{
			"jobId":         msg.JobID,
			"executionName": execName,
		})
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "error", err)
	}
}
