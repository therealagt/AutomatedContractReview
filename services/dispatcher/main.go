package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	executions "cloud.google.com/go/workflows/executions/apiv1"
	executionspb "cloud.google.com/go/workflows/executions/apiv1/executionspb"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type pubsubEnvelope struct {
	Message struct {
		Data string `json:"data"`
	} `json:"message"`
}

func main() {
	projectID := os.Getenv("PROJECT_ID")
	workflowID := os.Getenv("WORKFLOW_ID")
	if projectID == "" || workflowID == "" {
		log.Fatal("missing required env vars PROJECT_ID or WORKFLOW_ID")
	}

	ctx := context.Background()
	client, err := executions.NewClient(ctx)
	if err != nil {
		log.Fatalf("create executions client: %v", err)
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
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	log.Printf("dispatcher listening on :%s", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server failed: %v", err)
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

		var payload map[string]any
		if err := json.Unmarshal(decoded, &payload); err != nil {
			http.Error(w, "bad payload", http.StatusBadRequest)
			return
		}

		jobID, _ := payload["jobId"].(string)
		if jobID == "" {
			http.Error(w, "missing jobId", http.StatusBadRequest)
			return
		}

		argument, err := json.Marshal(payload)
		if err != nil {
			http.Error(w, "invalid payload", http.StatusBadRequest)
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()

		resp, err := client.CreateExecution(ctx, &executionspb.CreateExecutionRequest{
			Parent: workflowID,
			Execution: &executionspb.Execution{
				Argument: string(argument),
			},
		})
		if err != nil {
			st, ok := status.FromError(err)
			if ok && st.Code() == codes.ResourceExhausted {
				log.Printf("workflows quota hit, will retry: %v", err)
				http.Error(w, "workflows quota", http.StatusTooManyRequests)
				return
			}

			log.Printf("workflow start failed: %v", err)
			http.Error(w, "workflow start failed", http.StatusServiceUnavailable)
			return
		}

		log.Printf("started workflow execution %s for job %s", resp.GetName(), jobID)
		writeJSON(w, http.StatusAccepted, map[string]string{
			"jobId":         jobID,
			"executionName": resp.GetName(),
		})
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}
