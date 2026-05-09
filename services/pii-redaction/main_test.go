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

func TestParseGCSURI(t *testing.T) {
	t.Parallel()
	bucket, prefix, err := parseGCSURI("gs://my-bucket/extracted/job-1/")
	if err != nil {
		t.Fatal(err)
	}
	if bucket != "my-bucket" || prefix != "extracted/job-1/" {
		t.Fatalf("got bucket=%q prefix=%q", bucket, prefix)
	}
}

func TestParseGCSURIBad(t *testing.T) {
	t.Parallel()
	_, _, err := parseGCSURI("https://example.com/x")
	if err == nil {
		t.Fatal("want error")
	}
}

func TestNormalizeExtractedTextJSON(t *testing.T) {
	t.Parallel()
	raw := []byte(`{"text":"hello"}`)
	got := normalizeExtractedText(raw, "out.json")
	if got != "hello" {
		t.Fatalf("got %q", got)
	}
}

func TestRedactMethodNotAllowed(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	(&app{}).redactHandler(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestRedactInvalidBody(t *testing.T) {
	t.Parallel()
	rec := httptest.NewRecorder()
	(&app{}).redactHandler(rec, httptest.NewRequest(http.MethodPost, "/", strings.NewReader("{}")))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status %d", rec.Code)
	}
}
