// x12tojson -- convert an X12 EDI file (e.g. an 837P health-care claim) to JSON
// using the moov-io/x12 library (https://github.com/moov-io/x12).
//
// moov-io/x12 parses X12 into a nested, RULE-positional struct: segments carry
// only element positions ("01","02",...) and no segment NAME in the default JSON,
// which makes downstream SQL extraction fragile. Each moov segment type does
// expose a Name() method (CLM, NM1, SV1, HI, ...), so this tool walks the parsed
// document in order and emits a FLAT, LABELED segment stream:
//
//   {
//     "interchange_control_number": "000002120",
//     "transaction_type": "837p",
//     "segment_count": 123,
//     "segments": [
//       {"_segment":"NM1","claim_seq":0,"01":"85","02":"2","03":"BILLING PROVIDER",...},
//       {"_segment":"HL","claim_seq":1,"01":"2","03":"22","04":"0"},
//       {"_segment":"NM1","claim_seq":1,"01":"IL","03":"SMITH",...},
//       {"_segment":"CLM","claim_seq":1,"01":"1029353-03","02":"553.96",...},
//       {"_segment":"HI","claim_seq":1,...},
//       {"_segment":"SV1","claim_seq":1,...}, ...
//     ]
//   }
//
// claim_seq increments at each subscriber-level HL segment (HL03 == "22"), so a
// claim and all its segments (subscriber, payer, CLM, HI, LX/SV1, DTP) share one
// claim_seq; file-level/billing-provider segments are claim_seq 0. The Snowflake
// dbt canonical model flattens `segments` and filters by _segment + claim_seq.
//
// Usage:
//   x12tojson [--rule 837p|837d] [--tree] [--pretty] <file.x12 | ->
//
// Data is SYNTHETIC -- not real CMS/Medicare/Medicaid/PHI.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"reflect"
	"strings"

	"github.com/moov-io/x12/pkg/file"
	r837d "github.com/moov-io/x12/rule_5010_837d"
	r837p "github.com/moov-io/x12/rule_5010_837p"
)

// every moov segment type implements Name() string (CLM, NM1, SV1, HI, ...).
type namer interface{ Name() string }

func main() {
	rule := flag.String("rule", "837p", "X12 transaction rule: 837p | 837d")
	tree := flag.Bool("tree", false, "emit the raw moov nested tree instead of the flat labeled stream")
	pretty := flag.Bool("pretty", false, "indent the JSON output")
	flag.Parse()

	var data []byte
	var err error
	if args := flag.Args(); len(args) > 0 && args[0] != "-" {
		data, err = os.ReadFile(args[0])
	} else {
		data, err = io.ReadAll(os.Stdin)
	}
	if err != nil {
		log.Fatalf("read input: %v", err)
	}

	var raw strings.Builder
	sc := bufio.NewScanner(strings.NewReader(string(data)))
	sc.Buffer(make([]byte, 1<<20), 1<<20)
	for sc.Scan() {
		raw.WriteString(strings.TrimSpace(sc.Text()))
	}

	var ic *file.Interchange
	switch *rule {
	case "837p":
		ic = file.NewInterchange(&r837p.InterchangeRule)
	case "837d":
		ic = file.NewInterchange(&r837d.InterchangeRule)
	default:
		log.Fatalf("unknown --rule %q (want 837p or 837d)", *rule)
	}

	// "<" is the component (sub-element) separator (ISA16); elements split on "*",
	// segments on "~".
	if _, err = ic.Parse(raw.String(), "<"); err != nil {
		log.Fatalf("x12 parse (%s): %v", *rule, err)
	}

	var out any
	if *tree {
		out = ic
	} else {
		out = flatten(ic, *rule)
	}

	var b []byte
	if *pretty {
		b, err = json.MarshalIndent(out, "", "  ")
	} else {
		b, err = json.Marshal(out)
	}
	if err != nil {
		log.Fatalf("marshal json: %v", err)
	}
	os.Stdout.Write(b)
	fmt.Println()
}

// flatten walks the parsed interchange in document order and returns the labeled
// segment stream described in the package comment.
func flatten(ic *file.Interchange, rule string) map[string]any {
	var segs []map[string]any
	collect(reflect.ValueOf(ic), &segs)

	// Assign claim_seq: increment on each subscriber-level HL (HL03 == "22").
	seq := 0
	icn := ""
	for _, s := range segs {
		if s["_segment"] == "ISA" {
			if v, ok := s["13"].(string); ok {
				icn = strings.TrimSpace(v)
			}
		}
		if s["_segment"] == "HL" {
			if v, ok := s["03"].(string); ok && strings.TrimSpace(v) == "22" {
				seq++
			}
		}
		s["claim_seq"] = seq
	}

	return map[string]any{
		"interchange_control_number": icn,
		"transaction_type":           rule,
		"segment_count":              len(segs),
		"segments":                   segs,
	}
}

// collect appends each X12 segment (a pkg/segments type) to out in document
// order, recursing through exported struct fields and slices. NOTE: loops also
// implement Name() but live in pkg/loops -- they are containers, so we recurse
// into them rather than treating them as leaf segments.
func collect(v reflect.Value, out *[]map[string]any) {
	if !v.IsValid() {
		return
	}
	// Unwrap pointers / interfaces to the concrete value.
	if v.Kind() == reflect.Ptr || v.Kind() == reflect.Interface {
		if v.IsNil() {
			return
		}
		v = v.Elem()
		if !v.IsValid() {
			return
		}
	}

	// Leaf X12 segment? (implements Name() AND is a pkg/segments type)
	if isSegment(v) {
		*out = append(*out, segToMap(v.Interface(), v.Interface().(namer).Name()))
		return
	}

	switch v.Kind() {
	case reflect.Struct:
		t := v.Type()
		for i := 0; i < v.NumField(); i++ {
			if t.Field(i).PkgPath != "" { // skip unexported fields
				continue
			}
			collect(v.Field(i), out)
		}
	case reflect.Slice, reflect.Array:
		for i := 0; i < v.Len(); i++ {
			collect(v.Index(i), out)
		}
	case reflect.Ptr, reflect.Interface:
		collect(v, out)
	}
}

// isSegment reports whether v is a concrete moov X12 segment (not a loop/
// container). Both segments and loops implement Name(); only segments live in
// the pkg/segments package.
func isSegment(v reflect.Value) bool {
	if !v.CanInterface() {
		return false
	}
	if _, ok := v.Interface().(namer); !ok {
		return false
	}
	return strings.Contains(v.Type().PkgPath(), "moov-io/x12/pkg/segments")
}

// segToMap marshals a segment to its {"01":...} element map and labels it.
func segToMap(v any, name string) map[string]any {
	b, _ := json.Marshal(v)
	m := map[string]any{}
	_ = json.Unmarshal(b, &m)
	m["_segment"] = name
	return m
}
