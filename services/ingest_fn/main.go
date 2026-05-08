package function

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"

	"cloud.google.com/go/firestore"
	"cloud.google.com/go/pubsub"
	"github.com/GoogleCloudPlatform/functions-framework-go/functions"
	"github.com/cloudevents/sdk-go/v2/event"
	"github.com/google/uuid"
)

var (
	initOnce      sync.Once
	initErr       error
	firestoreCli  *firestore.Client
	publisherCli  *pubsub.Client
	jobsTopic     *pubsub.Topic
	projectID     string
	jobsTopicName string
)

func init() {
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
	functions.CloudEvent("Ingest", Ingest)
}

func isPDFObject(name string) bool {
	return strings.HasSuffix(strings.ToLower(name), ".pdf")
}

func Ingest(ctx context.Context, e event.Event) error {
	if err := initClients(ctx); err != nil {
		return err
	}

	var data struct {
		Bucket     string `json:"bucket"`
		Name       string `json:"name"`
		Generation string `json:"generation"`
	}
	if err := e.DataAs(&data); err != nil {
		slog.WarnContext(ctx, "decode event data failed", "error", err.Error())
		return nil
	}

	if data.Bucket == "" || data.Name == "" {
		return nil
	}
	if !isPDFObject(data.Name) {
		return nil
	}

	jobID := uuid.NewString()
	now := time.Now().UTC().Format(time.RFC3339Nano)

	_, err := firestoreCli.Collection("contractJobs").Doc(jobID).Set(ctx, map[string]any{
		"jobId":     jobID,
		"status":    "queued",
		"createdAt": now,
		"source": map[string]any{
			"bucket":     data.Bucket,
			"object":     data.Name,
			"generation": data.Generation,
		},
	})
	if err != nil {
		return err
	}

	payload, err := json.Marshal(map[string]any{
		"jobId": jobID,
		"source": map[string]any{
			"bucket":     data.Bucket,
			"object":     data.Name,
			"generation": data.Generation,
		},
	})
	if err != nil {
		return err
	}

	result := jobsTopic.Publish(ctx, &pubsub.Message{
		Data:       payload,
		Attributes: map[string]string{"jobId": jobID},
	})
	if _, err := result.Get(ctx); err != nil {
		return err
	}

	slog.InfoContext(ctx, "ingest job published",
		"jobId", jobID,
		"bucket", data.Bucket,
		"object", data.Name,
	)
	return nil
}

func initClients(ctx context.Context) error {
	initOnce.Do(func() {
		projectID = os.Getenv("PROJECT_ID")
		jobsTopicName = os.Getenv("JOBS_TOPIC_NAME")
		if projectID == "" || jobsTopicName == "" {
			initErr = errMissingEnv()
			return
		}

		firestoreCli, initErr = firestore.NewClient(ctx, projectID)
		if initErr != nil {
			return
		}

		publisherCli, initErr = pubsub.NewClient(ctx, projectID)
		if initErr != nil {
			_ = firestoreCli.Close()
			return
		}

		jobsTopic = publisherCli.Topic(jobsTopicName)
	})

	return initErr
}

func errMissingEnv() error {
	return &missingEnvError{message: "missing required env vars PROJECT_ID or JOBS_TOPIC_NAME"}
}

type missingEnvError struct {
	message string
}

func (e *missingEnvError) Error() string {
	return e.message
}
