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
	"strconv"
	"strings"
	"time"

	"cloud.google.com/go/firestore"
	"cloud.google.com/go/storage"
	"github.com/therealagt/automatedcontractreview/services/contracts"
	"golang.org/x/oauth2/google"
	aiplatform "google.golang.org/api/aiplatform/v1"
	"google.golang.org/api/option"
)

type app struct {
	firestore *firestore.Client
	storage   *storage.Client
	projectID string
	region    string
	model     string
	bucket    string
	httpAPI   *http.Client
	timeout   time.Duration
}

type analyzeRequest struct {
	JobID              string `json:"jobId"`
	RedactedTextRef    string `json:"redactedTextRef"`
	RedactionApplied   bool   `json:"redactionApplied"`
	Mode               string `json:"mode"`
}

const analysisInstruction = "You are a contract review assistant. Given the following redacted contract text, respond with a single JSON object only (no markdown) containing keys: summary (string), keyPoints (array of strings), risks (array of strings).\n\nRedacted contract text:\n"

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
	region := os.Getenv("REGION")
	model := os.Getenv("VERTEX_MODEL")
	bucket := os.Getenv("PROCESSED_BUCKET")
	if projectID == "" || region == "" || model == "" || bucket == "" {
		slog.Error("missing required env vars PROJECT_ID, REGION, VERTEX_MODEL, or PROCESSED_BUCKET")
		os.Exit(1)
	}

	timeout := time.Duration(0)
	if v := os.Getenv("HANDLER_TIMEOUT_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			timeout = time.Duration(n) * time.Second
		}
	}
	if timeout == 0 {
		timeout = 25 * time.Minute
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

	hc, err := google.DefaultClient(ctx, "https://www.googleapis.com/auth/cloud-platform")
	if err != nil {
		slog.Error("google default client", "error", err)
		os.Exit(1)
	}

	application := &app{
		firestore: fs,
		storage:   st,
		projectID: projectID,
		region:    region,
		model:     model,
		bucket:    bucket,
		httpAPI:   hc,
		timeout:   timeout,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)
	mux.HandleFunc("/analyze", application.analyzeHandler)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	slog.Info("gemini-analysis listening", "port", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("server failed", "error", err)
		os.Exit(1)
	}
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *app) analyzeHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req analyzeRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json body", http.StatusBadRequest)
		return
	}
	if req.JobID == "" || req.RedactedTextRef == "" || !strings.HasPrefix(req.RedactedTextRef, "gs://") {
		http.Error(w, "invalid payload", http.StatusBadRequest)
		return
	}
	if !req.RedactionApplied {
		http.Error(w, "redaction required", http.StatusBadRequest)
		return
	}

	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if mode != "sync" && mode != "batch" {
		http.Error(w, "mode must be sync or batch", http.StatusBadRequest)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), a.timeout)
	defer cancel()

	current, err := a.getCurrentStatus(ctx, req.JobID)
	if err != nil {
		slog.Error("read status", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "status read failed", http.StatusServiceUnavailable)
		return
	}
	if err := contracts.CanTransition(current, contracts.StatusAnalyzed); err != nil {
		slog.Warn("invalid transition", "jobId", req.JobID, "from", current, "to", contracts.StatusAnalyzed)
		http.Error(w, "invalid status transition", http.StatusConflict)
		return
	}

	rawRedacted, err := readGSFile(ctx, a.storage, req.RedactedTextRef)
	if err != nil {
		slog.Error("read redacted text", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "read redacted text failed", http.StatusBadGateway)
		return
	}
	redacted := string(rawRedacted)

	if mode == "batch" {
		jobName, err := a.startBatchJob(ctx, req.JobID, redacted)
		if err != nil {
			slog.Error("batch job", "jobId", req.JobID, "error", err.Error())
			http.Error(w, "batch job failed", http.StatusBadGateway)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"jobId":         req.JobID,
			"batchJobName":  jobName,
			"mode":          "batch",
		})
		return
	}

	out, err := a.callGenerateContent(ctx, redacted)
	if err != nil {
		slog.Error("generate content", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "vertex generate failed", http.StatusBadGateway)
		return
	}

	outObject := fmt.Sprintf("analysis/%s/result.json", req.JobID)
	if err := writeGCS(ctx, a.storage, a.bucket, outObject, out); err != nil {
		slog.Error("write analysis", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "write analysis failed", http.StatusBadGateway)
		return
	}

	resultRef := fmt.Sprintf("gs://%s/analysis/%s/", a.bucket, req.JobID)
	if err := a.mergeAnalyzed(ctx, req.JobID, resultRef); err != nil {
		slog.Error("firestore analyzed", "jobId", req.JobID, "error", err.Error())
		http.Error(w, "status update failed", http.StatusServiceUnavailable)
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"jobId":     req.JobID,
		"resultRef": resultRef,
		"mode":      "sync",
	})
}

func (a *app) startBatchJob(ctx context.Context, jobID, redactedText string) (string, error) {
	inObj := fmt.Sprintf("batch-input/%s/input.jsonl", jobID)
	line, err := json.Marshal(map[string]any{
		"request": map[string]any{
			"contents": []any{
				map[string]any{
					"role": "user",
					"parts": []any{
						map[string]any{"text": analysisInstruction + redactedText},
					},
				},
			},
		},
	})
	if err != nil {
		return "", err
	}
	if err := writeGCS(ctx, a.storage, a.bucket, inObj, append(line, '\n')); err != nil {
		return "", err
	}

	inURI := fmt.Sprintf("gs://%s/%s", a.bucket, inObj)
	outPrefix := fmt.Sprintf("gs://%s/batch-output/%s/", a.bucket, jobID)

	svc, err := aiplatform.NewService(ctx, option.WithHTTPClient(a.httpAPI))
	if err != nil {
		return "", err
	}

	parent := fmt.Sprintf("projects/%s/locations/%s", a.projectID, a.region)
	modelName := fmt.Sprintf("publishers/google/models/%s", a.model)
	job := &aiplatform.GoogleCloudAiplatformV1BatchPredictionJob{
		DisplayName: fmt.Sprintf("acr-gemini-%s", jobID),
		Model:       modelName,
		InputConfig: &aiplatform.GoogleCloudAiplatformV1BatchPredictionJobInputConfig{
			InstancesFormat: "jsonl",
			GcsSource: &aiplatform.GoogleCloudAiplatformV1GcsSource{
				Uris: []string{inURI},
			},
		},
		OutputConfig: &aiplatform.GoogleCloudAiplatformV1BatchPredictionJobOutputConfig{
			PredictionsFormat: "jsonl",
			GcsDestination: &aiplatform.GoogleCloudAiplatformV1GcsDestination{
				OutputUriPrefix: outPrefix,
			},
		},
	}

	created, err := svc.Projects.Locations.BatchPredictionJobs.Create(parent, job).Context(ctx).Do()
	if err != nil {
		return "", err
	}
	if created.Name == "" {
		return "", errors.New("empty batch job name")
	}
	return created.Name, nil
}

func (a *app) callGenerateContent(ctx context.Context, redactedText string) ([]byte, error) {
	url := fmt.Sprintf("https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/google/models/%s:generateContent",
		a.region, a.projectID, a.region, a.model)

	body := map[string]any{
		"contents": []any{
			map[string]any{
				"role": "user",
				"parts": []any{
					map[string]any{"text": analysisInstruction + redactedText},
				},
			},
		},
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := a.httpAPI.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("vertex %d: %s", resp.StatusCode, string(raw))
	}

	var parsed struct {
		Candidates []struct {
			Content struct {
				Parts []struct {
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"content"`
		} `json:"candidates"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, err
	}
	if len(parsed.Candidates) == 0 || len(parsed.Candidates[0].Content.Parts) == 0 {
		return nil, errors.New("empty candidates")
	}
	text := parsed.Candidates[0].Content.Parts[0].Text
	wrapped := map[string]any{
		"model":      a.model,
		"rawText":    text,
		"receivedAt": time.Now().UTC().Format(time.RFC3339Nano),
	}
	return json.Marshal(wrapped)
}

func (a *app) mergeAnalyzed(ctx context.Context, jobID, resultRef string) error {
	update := map[string]any{
		"status":            contracts.StatusAnalyzed,
		"schemaVersion":     contracts.SchemaVersion,
		"analysisCompletedAt": time.Now().UTC().Format(time.RFC3339Nano),
		"analysisResult": map[string]any{
			"resultRef": resultRef,
		},
	}
	_, err := a.firestore.Collection("contractJobs").Doc(jobID).Set(ctx, update, firestore.MergeAll)
	return err
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

func readGSFile(ctx context.Context, c *storage.Client, uri string) ([]byte, error) {
	bucket, key, err := parseGCS(uri)
	if err != nil {
		return nil, err
	}
	key = strings.TrimSuffix(key, "/")
	r, err := c.Bucket(bucket).Object(key).NewReader(ctx)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(r)
}

func parseGCS(uri string) (bucket, key string, err error) {
	const pfx = "gs://"
	if !strings.HasPrefix(uri, pfx) {
		return "", "", errors.New("not gs://")
	}
	rest := strings.TrimPrefix(uri, pfx)
	idx := strings.IndexByte(rest, '/')
	if idx < 0 {
		return rest, "", nil
	}
	return rest[:idx], rest[idx+1:], nil
}

func writeGCS(ctx context.Context, c *storage.Client, bucket, name string, data []byte) error {
	w := c.Bucket(bucket).Object(name).NewWriter(ctx)
	w.ContentType = "application/json"
	if _, err := io.Copy(w, bytes.NewReader(data)); err != nil {
		_ = w.Close()
		return err
	}
	return w.Close()
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		slog.Error("encode response", "error", err)
	}
}
