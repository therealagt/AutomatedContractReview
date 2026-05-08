package main

import (
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
}

func TestExtractMethodNotAllowed(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	h := (&app{}).extractHandler
	h(rec, httptest.NewRequest(http.MethodGet, "/extract", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestExtractInvalidJSON(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	h := (&app{}).extractHandler
	h(rec, httptest.NewRequest(http.MethodPost, "/extract", strings.NewReader("{")))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestExtractInvalidPayload(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	h := (&app{}).extractHandler
	h(rec, httptest.NewRequest(http.MethodPost, "/extract", strings.NewReader(`{"jobId":""}`)))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d", rec.Code)
	}
}
