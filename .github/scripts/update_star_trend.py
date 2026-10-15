#!/usr/bin/env python3
"""用 GitHub 当前 Star 数更新本地历史快照，并生成可悬停查看的 SVG 趋势图。"""

from __future__ import annotations

import json
import math
import os
import urllib.request
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape


REPO = "zzyoxml/md3Music"
HISTORY = Path("assets/star-history.json")
OUTPUT = Path("assets/star-trend.svg")
USER_AGENT = "md3music-star-trend-updater/2.0"
MAX_DAYS = 90


def fetch_stars() -> int:
    """从 GitHub API 读取当前 Star 数。"""
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}",
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
        },
    )
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.loads(response.read().decode("utf-8"))
    stars = int(data["stargazers_count"])
    if stars < 0:
        raise RuntimeError(f"无效的 Star 数：{stars}")
    return stars


def load_history() -> list[dict[str, int | str]]:
    """读取并验证已有历史；损坏时明确失败，避免静默清空曲线。"""
    if not HISTORY.exists():
        return []
    try:
        data = json.loads(HISTORY.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"无法读取历史快照 {HISTORY}: {error}") from error
    if not isinstance(data, list):
        raise RuntimeError(f"历史快照格式错误：{HISTORY} 应为数组")

    by_date: dict[str, dict[str, int | str]] = {}
    for item in data:
        if not isinstance(item, dict):
            raise RuntimeError(f"无效的历史快照：{item!r}")
        point_date = str(item.get("date", ""))
        stars = item.get("stars")
        if len(point_date) != 10 or point_date[4] != "-" or point_date[7] != "-":
            raise RuntimeError(f"无效的快照日期：{point_date!r}")
        try:
            date.fromisoformat(point_date)
            stars = int(stars)
        except (TypeError, ValueError) as error:
            raise RuntimeError(f"无效的历史快照：{item!r}") from error
        if stars < 0:
            raise RuntimeError(f"无效的 Star 数：{item!r}")
        point: dict[str, int | str] = {"date": point_date, "stars": stars}
        growth = item.get("daily_growth")
        if growth is not None:
            point["daily_growth"] = int(growth)
        by_date[point_date] = point
    return [by_date[point_date] for point_date in sorted(by_date)][-MAX_DAYS:]


def update_history(
    history: list[dict[str, int | str]], stars: int, today: date | None = None
) -> list[dict[str, int | str]]:
    """每天保留一个快照；同日重跑覆盖当天记录，并裁剪为最近 90 天。"""
    if stars < 0:
        raise ValueError("Star 数不能为负数")
    snapshot_date = (today or date.today()).isoformat()
    updated = [point.copy() for point in history if point["date"] != snapshot_date]
    previous = next(
        (point for point in reversed(updated) if str(point["date"]) < snapshot_date),
        None,
    )
    point: dict[str, int | str] = {"date": snapshot_date, "stars": stars}
    if previous is not None:
        point["daily_growth"] = stars - int(previous["stars"])
    updated.append(point)
    updated.sort(key=lambda item: str(item["date"]))
    return updated[-MAX_DAYS:]


def _tick_step(low: int, high: int) -> int:
    span = max(1, high - low)
    raw = span / 5
    magnitude = 10 ** math.floor(math.log10(raw))
    normalized = raw / magnitude
    factor = 1 if normalized <= 1 else 2 if normalized <= 2 else 5 if normalized <= 5 else 10
    return max(1, int(factor * magnitude))


def make_svg(points: list[dict[str, int | str]]) -> str:
    """生成与参考图相近的深色趋势图，悬停数据点显示日期、Star 和单日增长。"""
    if not points:
        raise ValueError("至少需要一个 Star 历史快照")

    width, height = 1320, 360
    left, right, top, bottom = 72, 28, 106, 54
    plot_width = width - left - right
    plot_height = height - top - bottom
    values = [int(point["stars"]) for point in points]
    raw_low, raw_high = min(values), max(values)
    step = _tick_step(raw_low, raw_high)
    y_min = max(0, (raw_low // step) * step)
    y_max = max(y_min + step, math.ceil(raw_high / step) * step)

    def x(index: int) -> float:
        return left if len(points) == 1 else left + index * plot_width / (len(points) - 1)

    def y(value: int | float) -> float:
        return top + (y_max - value) * plot_height / (y_max - y_min)

    # 用相邻点中点构造平滑曲线，保留所有原始快照作为悬停热区。
    coordinates = [(x(index), y(value)) for index, value in enumerate(values)]
    if len(coordinates) == 1:
        line_path = f"M {coordinates[0][0]:.1f} {coordinates[0][1]:.1f}"
    else:
        line_path = f"M {coordinates[0][0]:.1f} {coordinates[0][1]:.1f}"
        for index in range(1, len(coordinates) - 1):
            cx, cy = coordinates[index]
            nx, ny = coordinates[index + 1]
            mx, my = (cx + nx) / 2, (cy + ny) / 2
            line_path += f" Q {cx:.1f} {cy:.1f} {mx:.1f} {my:.1f}"
        line_path += f" L {coordinates[-1][0]:.1f} {coordinates[-1][1]:.1f}"
    baseline = top + plot_height
    area_path = f"{line_path} L {coordinates[-1][0]:.1f} {baseline:.1f} L {coordinates[0][0]:.1f} {baseline:.1f} Z"

    grid = []
    tick = (y_min // step) * step
    while tick <= y_max:
        position = y(tick)
        grid.append(
            f'<line x1="{left}" y1="{position:.1f}" x2="{width-right}" '
            f'y2="{position:.1f}" stroke="#45464a" stroke-dasharray="4 5"/>'
            f'<text x="{left-12}" y="{position+4:.1f}" text-anchor="end">{tick:,}</text>'
        )
        tick += step

    label_count = min(13, len(points))
    label_indexes = {
        round(index * (len(points) - 1) / max(1, label_count - 1))
        for index in range(label_count)
    }
    labels = []
    for index in sorted(label_indexes):
        point_date = date.fromisoformat(str(points[index]["date"]))
        labels.append(
            f'<text x="{x(index):.1f}" y="{height-34}" text-anchor="middle">'
            f"{point_date:%Y-%m-%d}</text>"
        )

    first, last = values[0], values[-1]
    delta = last - first
    latest_date = str(points[-1]["date"])
    delta_text = f"+{delta}" if delta >= 0 else str(delta)
    metric_x, metric_y, metric_width, metric_height, gap = 924, 15, 92, 55, 3
    metrics = [
        (f"{last:,}", "当前 Stars"),
        (delta_text, "首尾差值"),
        (str(len(points)), "快照数量"),
        (latest_date, "最近快照"),
    ]
    cards = []
    for index, (value, label) in enumerate(metrics):
        x0 = metric_x + index * (metric_width + gap)
        cards.append(
            f'<rect x="{x0}" y="{metric_y}" width="{metric_width}" height="{metric_height}" rx="5" fill="#303033"/>'
            f'<text x="{x0+9}" y="{metric_y+22}" class="metric-value">{escape(value)}</text>'
            f'<text x="{x0+9}" y="{metric_y+43}" class="metric-label">{escape(label)}</text>'
        )

    hover_groups = []
    for index, point in enumerate(points):
        px, py = coordinates[index]
        point_date = str(point["date"])
        growth = point.get("daily_growth")
        if growth is None and index > 0:
            growth = values[index] - values[index - 1]
        growth_text = "—" if growth is None else f"{int(growth):+d}"
        tooltip_width, tooltip_height = 124, 66
        tooltip_x = px + 13 if px < width - right - tooltip_width - 12 else px - tooltip_width - 13
        tooltip_y = max(top + 4, min(py - tooltip_height / 2, baseline - tooltip_height - 4))
        hover_groups.append(
            f'<g class="point">'
            f'<circle cx="{px:.1f}" cy="{py:.1f}" r="11" fill="transparent"/>'
            f'<g class="tooltip">'
            f'<line x1="{px:.1f}" y1="{top}" x2="{px:.1f}" y2="{baseline}" class="crosshair"/>'
            f'<circle cx="{px:.1f}" cy="{py:.1f}" r="4" fill="#69baff" stroke="#fff" stroke-width="1.5"/>'
            f'<rect x="{tooltip_x:.1f}" y="{tooltip_y:.1f}" width="{tooltip_width}" height="{tooltip_height}" rx="4" fill="#101113" opacity=".96"/>'
            f'<text x="{tooltip_x+8:.1f}" y="{tooltip_y+18:.1f}" class="tooltip-date">{escape(point_date)}</text>'
            f'<text x="{tooltip_x+8:.1f}" y="{tooltip_y+39:.1f}" class="tooltip-text">Stars: {values[index]:,}</text>'
            f'<text x="{tooltip_x+8:.1f}" y="{tooltip_y+57:.1f}" class="tooltip-text">单日增长: {escape(growth_text)}</text>'
            f'</g></g>'
        )

    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">
  <title id="title">MD3Music Star 趋势</title>
  <desc id="desc">截至 {latest_date}，当前 Stars {last:,}，首尾差值 {delta_text}，共 {len(points)} 个快照。悬停曲线可查看每日数据。</desc>
  <style>
    text {{ font-family: Arial, 'Microsoft YaHei', sans-serif; fill: #e7e7e9; }}
    .subtitle, .axis, .metric-label, .footer {{ fill: #a7a7ad; }}
    .subtitle {{ font-size: 12px; }} .axis {{ font-size: 11px; }}
    .metric-value {{ font-size: 14px; font-weight: 700; }} .metric-label {{ font-size: 11px; }}
    .footer {{ font-size: 10px; }} .tooltip-date {{ font-size: 12px; font-weight: 700; }}
    .tooltip-text {{ font-size: 12px; }} .crosshair {{ stroke: #b9b9bc; stroke-width: 1; }}
    .tooltip {{ opacity: 0; pointer-events: none; }} .point:hover .tooltip {{ opacity: 1; }}
  </style>
  <rect x="1" y="1" width="{width-2}" height="{height-2}" rx="9" fill="#1d1e20" stroke="#35363a"/>
  <text x="24" y="34" font-size="18" font-weight="700">Star 趋势</text>
  <text x="24" y="58" class="subtitle">最近 90 天本地快照趋势，前台不实时请求 GitHub。</text>
  {''.join(cards)}
  <g class="axis">{''.join(grid)}{''.join(labels)}</g>
  <path d="{area_path}" fill="#5baeff" fill-opacity=".13"/>
  <path d="{line_path}" fill="none" stroke="#63b7ff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <g>{''.join(hover_groups)}</g>
  <text x="24" y="{height-8}" class="footer">趋势基于本地每日快照，不在前台实时请求 GitHub。</text>
</svg>
'''


def main() -> None:
    history = load_history()
    stars = fetch_stars()
    history = update_history(history, stars)
    HISTORY.parent.mkdir(parents=True, exist_ok=True)
    HISTORY.write_text(
        json.dumps(history, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    OUTPUT.write_text(make_svg(history), encoding="utf-8", newline="\n")
    print(
        f"updated {OUTPUT} with {len(history)} snapshots through "
        f"{history[-1]['date']}, stars={stars}"
    )


if __name__ == "__main__":
    main()
