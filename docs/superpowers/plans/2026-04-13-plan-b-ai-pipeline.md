# Plan B: AI 管家管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the AI summary service that powers the butler experience — every inbox item gets an AI-generated one-line summary, and click-to-expand gets a full briefing. Includes image description and link/article analysis.

**Architecture:** New `AIInboxSummarizer` actor follows the same pattern as AIReplySuggester (own config overrides, prompt template, JSON parsing, audit logging). Summaries are generated async post-scan and cached. BriefingPanelView already has loading states — this plan populates the data.

**Tech Stack:** Swift, URLSession, OpenAI-compatible API, PromptLoader

---

## Tasks

### Task 1: Create AI summary prompt template + AIInboxSummarizer service
### Task 2: Create AI briefing prompt template + AIBriefingGenerator service  
### Task 3: Wire summarizer into ChatMonitor post-scan flow
### Task 4: Wire briefing into BriefingPanelView
### Task 5: Link/article content extraction (XML parsing + HTTP fetch)
### Task 6: Image file path resolution from WeChat storage
### Task 7: Tests + final verification
