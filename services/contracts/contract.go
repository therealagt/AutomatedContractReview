package contracts

import (
	"encoding/json"
	"errors"
)

const SchemaVersion = "v1"

const (
	StatusQueued    = "queued"
	StatusDocAIDone = "docai_done"
	StatusRedacted  = "redacted"
	StatusAnalyzed  = "analyzed"
	StatusFinalized = "finalized"
	StatusFailed    = "failed"
)

type Source struct {
	Bucket     string `json:"bucket"`
	Object     string `json:"object"`
	Generation string `json:"generation,omitempty"`
}

type JobMessage struct {
	SchemaVersion string `json:"schemaVersion"`
	JobID         string `json:"jobId"`
	Source        Source `json:"source"`
}

type JobRecord struct {
	SchemaVersion string `json:"schemaVersion" firestore:"schemaVersion"`
	JobID         string `json:"jobId" firestore:"jobId"`
	Status        string `json:"status" firestore:"status"`
	CreatedAt     string `json:"createdAt" firestore:"createdAt"`
	Source        Source `json:"source" firestore:"source"`
}

var (
	ErrInvalidStatusTransition = errors.New("invalid status transition")
	ErrInvalidStatusValue      = errors.New("invalid status value")
)

func NewSource(bucket, object, generation string) Source {
	return Source{
		Bucket:     bucket,
		Object:     object,
		Generation: generation,
	}
}

func NewQueuedJobMessage(jobID string, source Source) JobMessage {
	return JobMessage{
		SchemaVersion: SchemaVersion,
		JobID:         jobID,
		Source:        source,
	}
}

func NewQueuedJobRecord(jobID, createdAt string, source Source) JobRecord {
	return JobRecord{
		SchemaVersion: SchemaVersion,
		JobID:         jobID,
		Status:        StatusQueued,
		CreatedAt:     createdAt,
		Source:        source,
	}
}

func ParseJobMessage(data []byte) (JobMessage, error) {
	var msg JobMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		return JobMessage{}, err
	}
	if msg.SchemaVersion == "" {
		msg.SchemaVersion = SchemaVersion
	}
	if msg.JobID == "" || msg.Source.Bucket == "" || msg.Source.Object == "" {
		return JobMessage{}, errors.New("missing required job payload fields")
	}
	return msg, nil
}

func IsValidStatus(status string) bool {
	switch status {
	case StatusQueued, StatusDocAIDone, StatusRedacted, StatusAnalyzed, StatusFinalized, StatusFailed:
		return true
	default:
		return false
	}
}

func CanTransition(from, to string) error {
	if !IsValidStatus(from) || !IsValidStatus(to) {
		return ErrInvalidStatusValue
	}
	if to == StatusFailed {
		return nil
	}
	switch from {
	case StatusQueued:
		if to == StatusDocAIDone {
			return nil
		}
	case StatusDocAIDone:
		if to == StatusRedacted {
			return nil
		}
	case StatusRedacted:
		if to == StatusAnalyzed {
			return nil
		}
	case StatusAnalyzed:
		if to == StatusFinalized {
			return nil
		}
	}
	return ErrInvalidStatusTransition
}
