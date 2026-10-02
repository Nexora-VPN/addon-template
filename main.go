// Command addon-template is a minimal Nexora addon: it registers with a panel
// by claim code, receives the panel's signed events, answers the health
// check, and shows a page — everything an addon needs before it does
// anything of its own. Copy it, rename the slug, and build from here.
//
// Configuration comes from the environment, the way the install passes it:
//
//	NEXORA_CLAIM_CODE   the one-time code the panel registers with (drawn and logged when absent)
//	NEXORA_OPT_PORT     the port to listen on (install option "port")
//	NEXORA_OPT_TITLE    the page title (install option "title")
//	NEXORA_OPT_COUNT_USERS  "true" to show the panel's account count
//	NEXORA_DATA_DIR     where the credentials are kept (default ./data)
//	NEXORA_MANIFEST_FILE  a manifest to serve instead of the built-in one (a signed copy, say)
package main

import (
	"context"
	_ "embed"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/nexora-vpn/addon-kit/addon"
	"github.com/nexora-vpn/addon-kit/panel"
)

//go:embed nexora-addon.json
var builtinManifest []byte

func main() {
	raw := builtinManifest
	if path := os.Getenv("NEXORA_MANIFEST_FILE"); path != "" {
		var err error
		if raw, err = os.ReadFile(path); err != nil {
			log.Fatalf("NEXORA_MANIFEST_FILE: %v", err)
		}
	}
	dataDir := os.Getenv("NEXORA_DATA_DIR")
	if dataDir == "" {
		dataDir = "data"
	}
	a, err := addon.New(addon.Config{Manifest: raw, DataDir: dataDir}.FromEnv())
	if err != nil {
		log.Fatal(err)
	}

	var (
		mu     sync.Mutex
		recent []addon.Event
	)
	a.OnEvent(func(e addon.Event) {
		log.Printf("event %s: %s", e.Event, e.Data)
		mu.Lock()
		recent = append([]addon.Event{e}, recent...)
		if len(recent) > 20 {
			recent = recent[:20]
		}
		mu.Unlock()
		// The panel says goodbye before it deletes the token: forget the
		// credentials so the addon can be registered again.
		if e.Event == "panel.addon_removed" {
			if err := a.Forget(); err != nil {
				log.Printf("forget: %v", err)
			}
		}
	})

	mux := http.NewServeMux()
	a.Mount(mux)
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		view := pageView{Title: option("title", "Hello from a Nexora addon"), ClaimCode: a.ClaimCode()}
		if c := a.Credentials(); c != nil {
			view.Panel = c.Panel.URL
			view.Version = c.Panel.Version
			if option("count_users", "true") == "true" {
				view.Users = countUsers(r.Context(), c)
			}
		}
		mu.Lock()
		view.Events = append(view.Events, recent...)
		mu.Unlock()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := page.Execute(w, view); err != nil {
			log.Printf("page: %v", err)
		}
	})

	addr := ":" + option("port", "8090")
	log.Printf("listening on %s", addr)
	srv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	log.Fatal(srv.ListenAndServe())
}

func option(key, def string) string {
	if v := addon.Option(key); v != "" {
		return v
	}
	return def
}

// countUsers is the one call this addon makes to the panel: the account
// count, from the list's total.
func countUsers(ctx context.Context, c *addon.Credentials) string {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	client := &panel.Client{Base: c.Panel.URL, Token: c.Token}
	var list struct {
		Total int `json:"total"`
	}
	if err := client.Get(ctx, "/users?limit=1", &list); err != nil {
		return "unknown (" + err.Error() + ")"
	}
	return fmt.Sprint(list.Total)
}

type pageView struct {
	Title, ClaimCode, Panel, Version, Users string
	Events                                  []addon.Event
}

var page = template.Must(template.New("page").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{.Title}}</title>
<style>body{font:15px/1.6 system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}code{background:#eee;padding:0 .3em}</style>
</head><body>
<h1>{{.Title}}</h1>
{{if .ClaimCode}}
<p>Not registered yet. Register this addon on your panel's <b>Services → Addons</b> page with the claim code <code>{{.ClaimCode}}</code>.</p>
{{else}}
<p>Registered with <code>{{.Panel}}</code> (panel {{.Version}}).</p>
{{if .Users}}<p>The panel has <b>{{.Users}}</b> accounts.</p>{{end}}
<h2>Recent events</h2>
<ul>{{range .Events}}<li><code>{{.Event}}</code> {{printf "%s" .Data}}</li>{{else}}<li>None yet.</li>{{end}}</ul>
{{end}}
</body></html>`))
