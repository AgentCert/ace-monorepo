---
title: Reference
nav_order: 5
has_children: true
---

# Reference

Technical reference material — the API, storage model, compliance workflow, and testing.

<div class="topic-grid">
  <div class="topic-card">
    <div class="topic-card-title">API Reference</div>
    <div class="topic-card-desc">Endpoints and payloads for the certifier REST API — bucketing, extraction, aggregation, and certification routes.</div>
    <a href="{{ "/api.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">API Changes &amp; Fixes</div>
    <div class="topic-card-desc">Change log of API features, fixes, and breaking changes across certifier releases.</div>
    <a href="{{ "/api-changes-features-api-fixes.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Polling API Redesign</div>
    <div class="topic-card-desc">Design notes behind the async submit-then-poll job model — why synchronous HTTP wasn't viable.</div>
    <a href="{{ "/polling-api-redesign.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">MongoDB Storage</div>
    <div class="topic-card-desc">Collection schemas, index definitions, and the GridFS model for large certification artifacts.</div>
    <a href="{{ "/mongodb-storage.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">RAI Compliance</div>
    <div class="topic-card-desc">The responsible-AI compliance workflow — scoring, hard gates, PII detection, and adversarial input handling.</div>
    <a href="{{ "/rai-compliance-workflow.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
  <div class="topic-card">
    <div class="topic-card-title">Testing &amp; Coverage</div>
    <div class="topic-card-desc">Running the test suites across Go, Python, and TypeScript — plus the SonarQube coverage dashboard.</div>
    <a href="{{ "/testing.html" | relative_url }}" class="topic-card-link">Read →</a>
  </div>
</div>
