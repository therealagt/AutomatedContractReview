package contracts

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
)

type ctxLoggerKey struct{}

func WithRequestLogger(ctx context.Context, l *slog.Logger) context.Context {
	return context.WithValue(ctx, ctxLoggerKey{}, l)
}

func RequestLogger(ctx context.Context) *slog.Logger {
	if v := ctx.Value(ctxLoggerKey{}); v != nil {
		if l, ok := v.(*slog.Logger); ok {
			return l
		}
	}
	return slog.Default()
}

func parseCloudTraceContext(h string) (traceID, spanID string) {
	if h == "" {
		return "", ""
	}
	parts := strings.SplitN(h, "/", 2)
	if len(parts) < 2 {
		return "", ""
	}
	traceID = strings.TrimSpace(parts[0])
	rest := parts[1]
	if i := strings.Index(rest, ";"); i >= 0 {
		spanID = strings.TrimSpace(rest[:i])
	} else {
		spanID = strings.TrimSpace(rest)
	}
	return traceID, spanID
}

func TraceLoggingMiddleware(projectID string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tid, sid := parseCloudTraceContext(r.Header.Get("X-Cloud-Trace-Context"))
			if tid == "" {
				next.ServeHTTP(w, r)
				return
			}
			attrs := []any{
				"logging.googleapis.com/trace", "projects/" + projectID + "/traces/" + tid,
			}
			if sid != "" {
				attrs = append(attrs, "logging.googleapis.com/spanId", sid)
			}
			next.ServeHTTP(w, r.WithContext(WithRequestLogger(r.Context(), slog.With(attrs...))))
		})
	}
}
