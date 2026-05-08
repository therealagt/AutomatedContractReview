package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHealthz(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	healthz(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	var body map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil || body["status"] != "ok" {
		t.Fatalf("body %v err %v", body, err)
	}
}

func TestDispatchMethodNotAllowed(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	h := dispatchHandler(nil, "projects/p/locations/l/workflows/w")
	h(rec, httptest.NewRequest(http.MethodGet, "/dispatch", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestDispatchMissingJobID(t *testing.T) {
	t.Parallel()
	payload, _ := json.Marshal(map[string]any{"source": map[string]any{"bucket": "b", "object": "o.pdf"}})
	enc := base64.StdEncoding.EncodeToString(payload)
	body, _ := json.Marshal(map[string]any{"message": map[string]any{"data": enc}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/dispatch", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	h := dispatchHandler(nil, "projects/p/locations/l/workflows/w")
	h(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d", rec.Code)
	}
}
