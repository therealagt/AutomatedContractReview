package contracts

import "testing"

func TestParseCloudTraceContext(t *testing.T) {
	tid, sid := parseCloudTraceContext("105445aa7843bc8bf206b120000000/1;o=1")
	if tid != "105445aa7843bc8bf206b120000000" || sid != "1" {
		t.Fatalf("got trace=%q span=%q", tid, sid)
	}
	tid, sid = parseCloudTraceContext("")
	if tid != "" || sid != "" {
		t.Fatalf("empty: got trace=%q span=%q", tid, sid)
	}
}
