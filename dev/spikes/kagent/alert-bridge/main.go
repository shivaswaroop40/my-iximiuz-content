// alert-bridge turns Alertmanager webhooks into questions for a kagent agent.
//
//	Alertmanager --POST /alertmanager--> alert-bridge --A2A message/send--> kagent agent
//	                                          |
//	                                          +--> CHAT_WEBHOOK_URL (Slack-compatible {"text": ...}) or stdout
//
// Each alert gets its own conversation (contextId "alert-<fingerprint>"), so a re-fired alert
// continues the same thread with the agent. The bridge authenticates with its own projected
// ServiceAccount token, so kagent records the bridge as the caller.
//
// Env: AGENT_URL (http://kagent-controller.kagent:8083/api/a2a/<ns>/<agent>/), TOKEN_FILE
// (default /var/run/secrets/kubernetes.io/serviceaccount/token), CHAT_WEBHOOK_URL (optional),
// LISTEN (default :8080). Standard library only, so `go run main.go` needs no modules.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

type alert struct {
	Status      string            `json:"status"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	StartsAt    time.Time         `json:"startsAt"`
	Fingerprint string            `json:"fingerprint"`
}

type webhook struct {
	Alerts []alert `json:"alerts"`
}

var (
	agentURL  = os.Getenv("AGENT_URL")
	tokenFile = envOr("TOKEN_FILE", "/var/run/secrets/kubernetes.io/serviceaccount/token")
	chatURL   = os.Getenv("CHAT_WEBHOOK_URL")
	client    = &http.Client{Timeout: 5 * time.Minute}
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func newID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// prompt is what the on-call agent is asked about one alert.
func prompt(a alert) string {
	var labels []string
	for k, v := range a.Labels {
		labels = append(labels, k+"="+v)
	}
	return fmt.Sprintf("Alert %q is firing since %s.\nLabels: %s\nSummary: %s\n\n"+
		"Investigate with your tools and reply with: what is wrong, the most likely cause, and the next step for the on-call engineer.",
		a.Labels["alertname"], a.StartsAt.Format(time.RFC3339), strings.Join(labels, ", "), a.Annotations["summary"])
}

// ask sends one A2A message/send and returns the agent's text answer.
func ask(contextID, text string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": newID(), "method": "message/send",
		"params": map[string]any{"message": map[string]any{
			"role": "user", "messageId": newID(), "contextId": contextID,
			"parts": []map[string]string{{"kind": "text", "text": text}},
		}},
	})
	req, _ := http.NewRequest(http.MethodPost, agentURL, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if tok, err := os.ReadFile(tokenFile); err == nil {
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var out struct {
		Error  *struct{ Message string } `json:"error"`
		Result struct {
			Status    struct{ State string } `json:"status"`
			Artifacts []struct {
				Parts []struct{ Text string } `json:"parts"`
			} `json:"artifacts"`
		} `json:"result"`
	}
	raw, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", fmt.Errorf("HTTP %d: %.200s", resp.StatusCode, raw)
	}
	if out.Error != nil {
		return "", fmt.Errorf("agent error: %s", out.Error.Message)
	}
	var texts []string
	for _, a := range out.Result.Artifacts {
		for _, p := range a.Parts {
			texts = append(texts, p.Text)
		}
	}
	return strings.Join(texts, "\n"), nil
}

func post(text string) {
	if chatURL == "" {
		log.Printf("CHAT %s", text)
		return
	}
	body, _ := json.Marshal(map[string]string{"text": text})
	resp, err := client.Post(chatURL, "application/json", bytes.NewReader(body))
	if err != nil {
		log.Printf("chat webhook: %v", err)
		return
	}
	resp.Body.Close()
}

func handle(w http.ResponseWriter, r *http.Request) {
	var hook webhook
	if err := json.NewDecoder(r.Body).Decode(&hook); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	// Alertmanager retries slow receivers, so answer now and talk to the agent in the background.
	w.WriteHeader(http.StatusAccepted)
	for _, a := range hook.Alerts {
		if a.Status != "firing" {
			continue
		}
		go func(a alert) {
			ctx := "alert-" + a.Fingerprint
			start := time.Now()
			answer, err := ask(ctx, prompt(a))
			if err != nil {
				log.Printf("alert %s (%s): %v", a.Labels["alertname"], ctx, err)
				post(fmt.Sprintf(":warning: %s: the on-call agent failed: %v", a.Labels["alertname"], err))
				return
			}
			log.Printf("alert %s (%s) answered in %s", a.Labels["alertname"], ctx, time.Since(start).Round(time.Millisecond))
			post(fmt.Sprintf(":rotating_light: *%s*\n%s", a.Labels["alertname"], answer))
		}(a)
	}
}

func main() {
	if agentURL == "" {
		log.Fatal("AGENT_URL is required")
	}
	http.HandleFunc("POST /alertmanager", handle)
	http.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	addr := envOr("LISTEN", ":8080")
	log.Printf("alert-bridge listening on %s, agent %s", addr, agentURL)
	log.Fatal(http.ListenAndServe(addr, nil))
}
