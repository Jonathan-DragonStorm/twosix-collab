// Package h3fmt validates (and, for load-test data generation, produces)
// syntactically well-formed resolution-3 H3 index strings, without any
// external H3 library dependency -- no pure-Go H3 library has a track record
// on wasm targets, and the actual need here is format validation, not
// coordinate math.
//
// H3's 64-bit index layout: bit 63 reserved(0), bits 59-62 mode, bits 56-58
// reserved(0), bits 52-55 resolution, bits 45-51 base cell (0-121), bits 0-44
// fifteen 3-bit digits (0-6 for digits within the resolution, 7/"unused" for
// digits beyond it).
package h3fmt

import (
	"fmt"
	"strconv"
)

const (
	modeCell     = 1
	resolution3  = 3
	maxBaseCell  = 121
	unusedDigit  = 7
)

// Validate reports whether s is a syntactically well-formed resolution-3 H3
// cell index (15 hex chars).
func Validate(s string) error {
	if len(s) != 15 {
		return fmt.Errorf("h3 index must be 15 hex chars, got %d", len(s))
	}
	v, err := strconv.ParseUint(s, 16, 64)
	if err != nil {
		return fmt.Errorf("not valid hex: %w", err)
	}
	if v>>63&1 != 0 {
		return fmt.Errorf("reserved bit 63 must be 0")
	}
	if (v>>56)&0x7 != 0 {
		return fmt.Errorf("reserved bits 56-58 must be 0")
	}
	if mode := (v >> 59) & 0xf; mode != modeCell {
		return fmt.Errorf("mode must be %d (cell), got %d", modeCell, mode)
	}
	if res := (v >> 52) & 0xf; res != resolution3 {
		return fmt.Errorf("resolution must be %d, got %d", resolution3, res)
	}
	if baseCell := (v >> 45) & 0x7f; baseCell > maxBaseCell {
		return fmt.Errorf("base cell %d exceeds max %d", baseCell, maxBaseCell)
	}
	for digit := 0; digit < 15; digit++ {
		shift := uint(42 - digit*3)
		d := (v >> shift) & 0x7
		if digit < resolution3 {
			if d > 6 {
				return fmt.Errorf("digit %d must be 0-6 within resolution, got %d", digit, d)
			}
		} else if d != unusedDigit {
			return fmt.Errorf("digit %d beyond resolution must be unused marker %d, got %d", digit, unusedDigit, d)
		}
	}
	return nil
}

// Generate produces a syntactically valid resolution-3 H3 index string from
// a base cell (0-121) and three resolution-path digits (each 0-6), for
// synthetic load-test data.
func Generate(baseCell uint64, d1, d2, d3 uint64) string {
	v := uint64(modeCell) << 59
	v |= uint64(resolution3) << 52
	v |= (baseCell & 0x7f) << 45
	v |= (d1 & 0x7) << 42
	v |= (d2 & 0x7) << 39
	v |= (d3 & 0x7) << 36
	for digit := 3; digit < 15; digit++ {
		shift := uint(42 - digit*3)
		v |= uint64(unusedDigit) << shift
	}
	return fmt.Sprintf("%015x", v)
}
