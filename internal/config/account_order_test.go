package config

import (
	"path/filepath"
	"reflect"
	"testing"
)

func TestAccountOrderRoundTrip(t *testing.T) {
	cfg := Default()
	cfg.RoutingStrategy = "fill-first"
	cfg.AccountOrder = ParseAccountOrder(" primary@example.com,secondary@example.com,,primary@example.com ")
	want := []string{"primary@example.com", "secondary@example.com"}
	if !reflect.DeepEqual(cfg.AccountOrder, want) {
		t.Fatalf("order=%v", cfg.AccountOrder)
	}
	path := filepath.Join(t.TempDir(), ".env")
	if err := cfg.Save(path); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(loaded.AccountOrder, want) {
		t.Fatalf("saved order=%v", loaded.AccountOrder)
	}
}
