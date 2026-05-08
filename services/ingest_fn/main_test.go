package function

import "testing"

func TestIsPDFObject(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		want bool
	}{
		{"doc.pdf", true},
		{"path/to/X.PDF", true},
		{"notes.txt", false},
		{"file.pdfx", false},
		{"", false},
	}
	for _, tc := range cases {
		if got := isPDFObject(tc.name); got != tc.want {
			t.Errorf("isPDFObject(%q) = %v want %v", tc.name, got, tc.want)
		}
	}
}
