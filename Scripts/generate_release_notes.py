#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path


SECTION_LABELS = OrderedDict(
    [
        ("assistant", "Assistant and chat"),
        ("voice", "Voice and dictation"),
        ("automation", "Tools and automation"),
        ("platform", "Platform and polish"),
        ("fixes", "Included fixes"),
    ]
)

HEADING_ALIASES = {
    "ask": "assistant",
    "ask - assistant conversations": "assistant",
    "assistant conversations": "assistant",
    "speak": "voice",
    "speak - voice and dictation": "voice",
    "voice and dictation": "voice",
    "act": "automation",
    "act - agentic automation": "automation",
    "agentic automation": "automation",
    "infrastructure": "platform",
    "changes": "fixes",
}

SKIP_COMMIT_PREFIXES = ("ci:", "Initial plan")
SKIP_COMMIT_SUBJECTS = {
    "Update web/chat/src/components/ActivityIcon.tsx",
    "Update web/chat/src/components/SidebarView.tsx",
    "feat: Introduce shell, window, and accessibility automation services and tools.",
    "Add skills system, session management, computer use, image generation, conversation checkpoints, and chat UI overhaul",
}
SPECIAL_COMMIT_REWRITES = {
    "Restore React assistant surfaces and fix HUD layout loops": "Restored the React sidebar and React composer, and fixed the notch HUD layout loop that could crash the app.",
    "Handle Codex review on project folder dedupe": "Combined projects that point to the same linked folder, including case-only path differences on macOS volumes.",
    "Redesign assistant bottom status bar, add settings navigation model, and update gitignore": "Refreshed the assistant status area and improved settings navigation flow.",
    "docs: add product preview images and a VS Code launch configuration, and update README with comprehensive feature details and setup guides.": "Expanded the docs with preview images, a VS Code launch configuration, and clearer setup and feature guides.",
}


def run_command(args: list[str]) -> str:
    completed = subprocess.run(args, check=True, text=True, capture_output=True)
    return completed.stdout.strip()


def run_json(args: list[str]) -> object:
    return json.loads(run_command(args))


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def normalize_text(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip().lower()


def clean_markdown(text: str) -> str:
    cleaned = text.strip()
    cleaned = re.sub(r"`([^`]+)`", r"\1", cleaned)
    cleaned = re.sub(r"\*\*([^*]+)\*\*", r"\1", cleaned)
    cleaned = re.sub(r"\*([^*]+)\*", r"\1", cleaned)
    cleaned = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", cleaned)
    cleaned = re.sub(r"^[-*]\s+", "", cleaned)
    cleaned = cleaned.replace("—", "-")
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if cleaned and cleaned[-1] not in ".!?":
        cleaned += "."
    return cleaned


def sanitize_body(body: str) -> str:
    without_comments = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    if "START COPILOT CODING AGENT TIPS" in without_comments:
        without_comments = without_comments.split("START COPILOT CODING AGENT TIPS", 1)[0]
    return without_comments.strip()


def classify_heading(heading: str) -> str | None:
    lowered = normalize_text(heading)
    lowered = lowered.replace("–", "-").replace("—", "-")
    return HEADING_ALIASES.get(lowered)


def parse_pr_sections(body: str) -> dict[str, list[str]]:
    sections: dict[str, list[str]] = {key: [] for key in SECTION_LABELS}
    current_section: str | None = None

    for raw_line in sanitize_body(body).splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped:
            continue

        heading_match = re.match(r"^#{2,3}\s+(.+)$", stripped)
        if heading_match:
            current_section = classify_heading(heading_match.group(1))
            continue

        if current_section and stripped.startswith("- "):
            sections[current_section].append(clean_markdown(stripped[2:]))

    return {key: value for key, value in sections.items() if value}


def get_sorted_tags() -> list[str]:
    output = run_command(["git", "tag", "--sort=-version:refname"])
    return [line.strip() for line in output.splitlines() if line.strip()]


def get_previous_tag(current_tag: str) -> str | None:
    tags = get_sorted_tags()
    try:
        current_index = tags.index(current_tag)
    except ValueError as exc:
        raise SystemExit(f"Tag {current_tag} was not found in the local git tags.") from exc

    if current_index + 1 >= len(tags):
        return None
    return tags[current_index + 1]


def get_tag_date(tag: str) -> dt.datetime:
    return parse_time(run_command(["git", "log", "-1", "--format=%cI", tag]))


def get_release_prs(repo: str, previous_tag: str, current_tag: str, start: dt.datetime, end: dt.datetime) -> list[dict[str, object]]:
    merge_messages = run_command(["git", "log", "--format=%s", f"{previous_tag}..{current_tag}"]).splitlines()
    pr_numbers: list[int] = []
    for message in merge_messages:
        match = re.search(r"Merge pull request #(\d+)", message)
        if match:
            pr_numbers.append(int(match.group(1)))

    if pr_numbers:
        prs = []
        for pr_number in reversed(pr_numbers):
            pr = run_json(
                [
                    "gh",
                    "pr",
                    "view",
                    str(pr_number),
                    "--repo",
                    repo,
                    "--json",
                    "number,title,body,mergedAt,url",
                ]
            )
            prs.append(pr)
        return prs

    search_query = f"merged:>{start.isoformat()} merged:<={(end + dt.timedelta(minutes=10)).isoformat()}"
    prs = run_json(
        [
            "gh",
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            "merged",
            "--limit",
            "100",
            "--search",
            search_query,
            "--json",
            "number,title,body,mergedAt,url",
        ]
    )

    filtered: list[dict[str, object]] = []
    for pr in prs:
        merged_at = parse_time(pr["mergedAt"])
        if start < merged_at <= end + dt.timedelta(minutes=10):
            filtered.append(pr)

    return sorted(filtered, key=lambda pr: parse_time(pr["mergedAt"]))


def get_extra_commit_highlights(previous_tag: str, current_tag: str, prs: list[dict[str, object]]) -> list[str]:
    output = run_command(["git", "log", "--format=%s", "--no-merges", f"{previous_tag}..{current_tag}"])
    subjects = [line.strip() for line in output.splitlines() if line.strip()]
    normalized_pr_titles = {normalize_text(pr["title"]) for pr in prs}

    extras: list[str] = []
    for subject in subjects:
        if subject in SKIP_COMMIT_SUBJECTS:
            continue
        if any(subject.startswith(prefix) for prefix in SKIP_COMMIT_PREFIXES):
            continue
        if normalize_text(subject) in normalized_pr_titles:
            continue

        rewritten = SPECIAL_COMMIT_REWRITES.get(subject)
        if rewritten:
            extras.append(rewritten)
            continue

        normalized_subject = normalize_text(subject)
        if normalized_subject.startswith("apply review feedback:"):
            continue
        if normalized_subject.startswith("feat: "):
            subject = subject[6:]
        if normalized_subject.startswith("docs: "):
            subject = subject[6:]
        extras.append(clean_markdown(subject))

    deduped: list[str] = []
    seen: set[str] = set()
    for item in extras:
        normalized_item = normalize_text(item)
        if normalized_item in seen:
            continue
        seen.add(normalized_item)
        deduped.append(item)
    return deduped


def build_release_notes(repo: str, current_tag: str) -> str:
    previous_tag = get_previous_tag(current_tag)
    if previous_tag is None:
        raise SystemExit(f"Could not determine a previous tag for {current_tag}.")

    start = get_tag_date(previous_tag)
    end = get_tag_date(current_tag)
    prs = get_release_prs(repo, previous_tag, current_tag, start, end)
    extra_commits = get_extra_commit_highlights(previous_tag, current_tag, prs)

    section_bullets: dict[str, list[str]] = {key: [] for key in SECTION_LABELS}
    for pr in prs:
        parsed_sections = parse_pr_sections(pr["body"] or "")
        for section_key, bullets in parsed_sections.items():
            section_bullets[section_key].extend(bullets)

    release_lines: list[str] = [
        f"Open Assist {current_tag} includes everything merged since `{previous_tag}`.",
        "",
    ]

    if any(section_bullets.values()) or extra_commits:
        release_lines.append("## Highlights")
        release_lines.append("")

        for section_key, section_label in SECTION_LABELS.items():
            bullets = section_bullets[section_key]
            if not bullets:
                continue
            release_lines.append(f"### {section_label}")
            for bullet in bullets:
                release_lines.append(f"- {bullet}")
            release_lines.append("")

        if extra_commits:
            release_lines.append("### UI and follow-up fixes")
            for bullet in extra_commits:
                release_lines.append(f"- {bullet}")
            release_lines.append("")

    release_lines.append("## Pull requests in this release")
    for pr in prs:
        release_lines.append(f"- [#{pr['number']}]({pr['url']}) {pr['title']}")
    release_lines.append("")
    release_lines.append(f"**Full Changelog**: https://github.com/{repo}/compare/{previous_tag}...{current_tag}")

    return "\n".join(release_lines).strip() + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate fuller GitHub release notes from tag history and merged PRs.")
    parser.add_argument("--repo", required=True, help="GitHub repo in owner/name form.")
    parser.add_argument("--tag", required=True, help="Release tag to generate notes for.")
    parser.add_argument("--output", required=True, help="Output markdown file.")
    args = parser.parse_args()

    notes = build_release_notes(args.repo, args.tag)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(notes, encoding="utf-8")
    print(f"Wrote release notes to {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
