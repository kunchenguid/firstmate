use chrono::{DateTime, Local};

use super::{
    github_review::{display_status, github_status_color, review_sections},
    *,
};
use crate::{app::visible_github_feedback_indices, github::PullRequestComment};

#[cfg(test)]
mod tests;

// Navigation and rendering measure the same styled, wrapped document at the actual viewport width.
pub(crate) fn github_comments_navigation(app: &App, terminal: Rect) -> (Vec<(u16, u16)>, u16) {
    let area = comments_body_area(review_sections(shell_areas(terminal)[1], app)[3]);
    let ranges = app
        .github_review
        .as_ref()
        .and_then(|review| {
            if let GitHubDetailState::Ready(detail) = &review.detail {
                Some(comment_document(detail, review, area.width).1)
            } else {
                None
            }
        })
        .unwrap_or_default();
    (ranges, area.height)
}

fn comments_body_area(area: Rect) -> Rect {
    Layout::vertical([Constraint::Length(2), Constraint::Min(0)]).split(area)[1]
}

pub(super) fn render_comments(frame: &mut Frame, area: Rect, review: &GitHubReviewState) {
    let body_area = comments_body_area(area);
    let (lines, ranges) = match &review.detail {
        GitHubDetailState::Loading => (vec![Line::raw("Loading pull request...")], Vec::new()),
        GitHubDetailState::Error(message) => (
            vec![Line::styled(message, Style::default().fg(RED))],
            Vec::new(),
        ),
        GitHubDetailState::Ready(detail) => comment_document(detail, review, body_area.width),
    };
    if let GitHubDetailState::Ready(detail) = &review.detail {
        let visible = detail
            .comments
            .iter()
            .filter(|comment| review.show_resolved || !comment.resolved)
            .count();
        let position = if ranges.is_empty() {
            0
        } else {
            review.comment_selected + 1
        };
        let status = format!(
            "{visible}/{} messages · [R] {} · {position}/{} discussions",
            detail.comments.len(),
            if review.show_resolved {
                "Resolved shown"
            } else {
                "Resolved hidden"
            },
            ranges.len()
        );
        frame.render_widget(
            Paragraph::new(status).style(Style::default().fg(MUTED_TEXT)),
            Rect {
                height: area.height.min(1),
                ..area
            },
        );
    }
    render_document(frame, body_area, lines, review.comment_scroll);
}

fn comment_document<'a>(
    detail: &'a PullRequestDetail,
    review: &GitHubReviewState,
    width: u16,
) -> (Vec<Line<'a>>, Vec<(u16, u16)>) {
    let mut lines = Vec::new();
    let mut ranges = Vec::new();
    let mut row = 0u16;
    for (selected_index, index) in visible_github_feedback_indices(detail, review.show_resolved)
        .into_iter()
        .enumerate()
    {
        let comment = &detail.comments[index];
        let count = if comment.thread.is_some() {
            detail.comments[index..]
                .iter()
                .take_while(|reply| reply.thread == comment.thread)
                .count()
        } else {
            1
        };
        let group = &detail.comments[index..index + count];
        let key = comment.feedback_key(index);
        let collapsed = review.collapsed_feedback.contains(&key);
        let selected = selected_index == review.comment_selected;
        let mut item = Vec::new();
        let label = if comment.thread.is_some() {
            if comment
                .thread
                .as_deref()
                .is_some_and(|id| id.starts_with("inferred-comment-chain-"))
            {
                "Comment replies".into()
            } else if comment.resolved {
                "Resolved Thread".into()
            } else {
                "Unresolved Thread".into()
            }
        } else if let Some(state) = &comment.review_state {
            format!("Review · {}", display_status(state))
        } else {
            "Comment".into()
        };
        let color = if comment.resolved {
            MUTED_TEXT
        } else if let Some(state) = &comment.review_state {
            github_status_color(state)
        } else {
            TEAL
        };
        let mut header = vec![
            Span::styled(
                if selected { "› " } else { "  " },
                Style::default().fg(TEAL),
            ),
            Span::styled(
                if review.selected_feedback.contains(&key) {
                    "[x] "
                } else {
                    "[ ] "
                },
                Style::default().fg(TEAL),
            ),
            Span::styled(
                format!("{} {label}", if collapsed { "▸" } else { "▾" }),
                Style::default().fg(color).add_modifier(Modifier::BOLD),
            ),
        ];
        if let Some(path) = &comment.path {
            header.push(Span::styled(
                format!(
                    " · {path}{}",
                    comment
                        .line
                        .map(|line| format!(":{line}"))
                        .unwrap_or_default()
                ),
                Style::default().fg(BLUE),
            ));
        }
        if count > 1 {
            header.push(Span::styled(
                format!(" · {count} messages"),
                Style::default().fg(MUTED_TEXT),
            ));
        }
        item.push(Line::from(header).style(if selected {
            Style::default().bg(MUTED_SURFACE)
        } else {
            Style::default()
        }));
        if collapsed {
            let preview = markdown_lines(&comment.body)
                .iter()
                .map(ToString::to_string)
                .filter(|line| !line.trim().is_empty())
                .collect::<Vec<_>>()
                .join(" ");
            // Keep collapsed previews to one display row, including wide Unicode characters.
            let preview = format!(
                "  {}: {}",
                comment.author,
                if preview.is_empty() {
                    "No review message."
                } else {
                    &preview
                }
            );
            item.push(clipped_preview(&preview, width));
        } else {
            if let Some(diff) = &comment.diff_hunk {
                item.extend(diff.lines().map(|line| {
                    Line::from(vec![
                        Span::styled("  │ ", Style::default().fg(BORDER)),
                        Span::styled(
                            line,
                            Style::default().fg(if line.starts_with('+') {
                                GREEN
                            } else if line.starts_with('-') {
                                RED
                            } else {
                                MUTED_TEXT
                            }),
                        ),
                    ])
                }));
            }
            for (reply_index, reply) in group.iter().enumerate() {
                if reply_index > 0 {
                    item.push(Line::raw(""));
                }
                item.push(comment_author(reply));
                let body = markdown_lines(&reply.body);
                if body.is_empty() {
                    item.push(Line::styled(
                        "  No review message.",
                        Style::default().fg(MUTED_TEXT),
                    ));
                } else {
                    item.extend(body.into_iter().map(|mut line| {
                        line.spans.insert(0, Span::raw("  "));
                        line
                    }));
                }
            }
            item.push(Line::raw(""));
        }
        let height = Paragraph::new(item.clone())
            .wrap(Wrap { trim: false })
            .line_count(width);
        let end = row.saturating_add(u16::try_from(height).unwrap_or(u16::MAX));
        ranges.push((row, end));
        row = end;
        lines.extend(item);
    }
    if lines.is_empty() {
        lines.push(Line::styled(
            if detail.comments.is_empty() {
                "No comments yet."
            } else {
                "All discussions are resolved. Press R to show them."
            },
            Style::default().fg(MUTED_TEXT),
        ));
    }
    (lines, ranges)
}

fn clipped_preview(preview: &str, width: u16) -> Line<'static> {
    let mut text = String::new();
    for character in preview.chars() {
        text.push(character);
        if Line::raw(text.clone()).width() > usize::from(width.saturating_sub(1)) {
            text.pop();
            text.push('…');
            break;
        }
    }
    Line::styled(text, Style::default().fg(MUTED_TEXT))
}

fn comment_author(comment: &PullRequestComment) -> Line<'_> {
    let mut spans = vec![Span::styled(
        format!("  {}", comment.author),
        Style::default().fg(TEAL).add_modifier(Modifier::BOLD),
    )];
    if let Some(timestamp) = comment
        .created_at
        .as_deref()
        .and_then(|value| DateTime::parse_from_rfc3339(value).ok())
    {
        spans.push(Span::styled(
            format!(
                " · {}",
                timestamp.with_timezone(&Local).format("%b %d, %Y %H:%M")
            ),
            Style::default().fg(MUTED_TEXT),
        ));
    }
    Line::from(spans)
}
