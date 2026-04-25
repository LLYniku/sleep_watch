#!/usr/bin/env python3
import argparse
import base64
import json
import os
import re
import secrets
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from openai import OpenAI


SYSTEM_PROMPT = """你是一个谨慎、温和、支持型的个人健康分析助手。
你会根据 Apple Watch / HealthKit 数据和用户自定义 profile 生成中文健康报告。
报告应帮助用户建立可持续的作息、运动、恢复和专注节奏，而不是鼓励短期硬扛。

要求：
1. 不做医学诊断，不替代医生；只能做生活方式、恢复、运动、睡眠、压力管理建议。
2. 语气必须像一位可靠、温柔、务实的教练：鼓励但不空泛，具体但不苛责。
3. 不使用羞辱、催促、比较、责备、吓唬式表达；不要说“你必须”“你太差”“再不怎样就怎样”。
4. 明确告诉用户：休息、运动和睡眠不是偷懒，而是长期表现的一部分。
5. 建议必须贴合用户 profile；如果 profile 为空，则按普通久坐办公/学习场景处理。
6. 如果数据一般，也要先承认用户已经在努力，再给出一个小而可执行的改进动作。
7. 必须覆盖：总体评价、早晨鼓励、睡眠恢复、心血管/压力、活动与久坐、呼吸/血氧、今日执行计划、劳逸结合。
8. 每天给一条适合上午看到的鼓励话语，帮助用户降低过度压力化，语气可以温暖一些，但不要鸡汤。
9. 数据缺失时明确说明“数据不足”，不要编造数值；异常值必须提示可能是佩戴或单位问题。
10. 只输出 JSON，不要 Markdown，不要代码块。

JSON schema:
{
  "report_date": "YYYY-MM-DD",
  "overall": {
    "score": 0-100,
    "title": "短标题",
    "assessment": "60字内总体评价",
    "recommendation": "60字内最重要建议"
  },
  "sections": [
    {
      "id": "morning_encouragement|sleep|cardio|activity|respiration|focus_plan|rest_balance",
      "title": "中文标题",
      "status": "优秀|稳定|注意|风险|数据不足",
      "score": 0-100,
      "metrics": [{"label": "指标名", "value": "带单位的值"}],
      "assessment": "80字内评价",
      "advice": "80字内建议"
    }
  ]
}"""

DEFAULT_USER_PROFILE = "久坐办公或学习人群；希望获得温和、具体、可执行的健康建议。"


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--out-dir", default="summaries")
    parser.add_argument("--data-dir", default="data")
    parser.add_argument("--report-dir", default="reports")
    return parser.parse_args()


def load_payload(event_path: str) -> dict:
    if not event_path:
        raise SystemExit("Missing GITHUB_EVENT_PATH or --event")

    event = json.loads(Path(event_path).read_text(encoding="utf-8"))
    if "client_payload" in event:
        return normalize_payload(event["client_payload"])

    inputs = event.get("inputs") or {}
    payload_json = inputs.get("payload_json")
    if payload_json:
        return normalize_payload(json.loads(payload_json))

    raise SystemExit("No health payload found in repository_dispatch client_payload or workflow_dispatch payload_json")


def normalize_payload(payload: dict) -> dict:
    if "analysis_date" in payload:
        payload.pop("persona", None)
        payload.setdefault("sleep_samples", payload.get("samples", []))
        payload.setdefault("quantity_metrics", [])
        payload.setdefault("stand_hours", [])
        payload.setdefault("data_gaps", [])
        return payload

    return {
        "analysis_date": payload.get("sleep_date", datetime.now().strftime("%Y-%m-%d")),
        "window_start": payload.get("window_start"),
        "window_end": payload.get("window_end"),
        "sleep_window_start": payload.get("window_start"),
        "sleep_window_end": payload.get("window_end"),
        "generated_at": payload.get("generated_at"),
        "source": payload.get("source", "apple_watch_healthkit"),
        "sleep_samples": payload.get("samples", []),
        "quantity_metrics": [],
        "stand_hours": [],
        "data_gaps": [],
    }


def summarize_metrics(payload: dict) -> dict:
    sleep_totals = defaultdict(float)
    for sample in payload.get("sleep_samples", []):
        stage = sample.get("stage", "unknown")
        sleep_totals[stage] += float(sample.get("duration_minutes", 0) or 0)

    asleep_stages = ["asleep_unspecified", "asleep_core", "asleep_deep", "asleep_rem"]
    total_asleep = sum(sleep_totals[stage] for stage in asleep_stages)

    quantities = {}
    for metric in payload.get("quantity_metrics", []):
        quantities[metric.get("id", metric.get("title", "unknown"))] = metric

    stand_hours = payload.get("stand_hours", [])
    stood_hours = sum(1 for item in stand_hours if item.get("stood"))

    return {
        "analysis_date": payload.get("analysis_date", "unknown"),
        "persona": user_profile(),
        "sleep": {
            "sample_count": len(payload.get("sleep_samples", [])),
            "total_asleep_minutes": round(total_asleep, 1),
            "awake_minutes": round(sleep_totals["awake"], 1),
            "in_bed_minutes": round(sleep_totals["in_bed"], 1),
            "core_minutes": round(sleep_totals["asleep_core"], 1),
            "deep_minutes": round(sleep_totals["asleep_deep"], 1),
            "rem_minutes": round(sleep_totals["asleep_rem"], 1),
            "unspecified_asleep_minutes": round(sleep_totals["asleep_unspecified"], 1),
        },
        "quantities": quantities,
        "stand": {
            "sample_count": len(stand_hours),
            "stood_hours": stood_hours,
        },
        "data_gaps": payload.get("data_gaps", []),
        "window_start": payload.get("window_start"),
        "window_end": payload.get("window_end"),
        "sleep_window_start": payload.get("sleep_window_start"),
        "sleep_window_end": payload.get("sleep_window_end"),
    }


def openai_base_url() -> str:
    base_url = os.environ.get("OPENAI_API_BASE") or os.environ.get("OPENAI_BASE_URL") or "https://api.openai.com/v1"
    return base_url.rstrip("/")


def user_profile() -> str:
    return os.environ.get("USER_PERSONA", "").strip() or DEFAULT_USER_PROFILE


def call_openai(payload: dict, metrics: dict) -> dict:
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise SystemExit("Missing OPENAI_API_KEY secret")

    model = os.environ.get("OPENAI_MODEL") or os.environ.get("MODEL_NAME") or "gpt-5.4-mini"
    wire_api = os.environ.get("OPENAI_WIRE_API", "responses").lower().replace("-", "_").replace(".", "_")
    requested_effort = os.environ.get("OPENAI_REASONING_EFFORT", "medium")
    effort = "medium" if requested_effort == "xhigh" else requested_effort
    disable_response_storage = os.environ.get("OPENAI_DISABLE_RESPONSE_STORAGE", "true").lower() == "true"
    safe_payload = dict(payload)
    safe_payload.pop("persona", None)

    user_prompt = {
        "metrics": metrics,
        "raw_payload": safe_payload,
        "personalization_contract": {
            "identity": metrics.get("persona", DEFAULT_USER_PROFILE),
            "pressure_context": "如果用户 profile 提到压力、学习、工作、照护、运动目标或恢复需求，请优先贴合这些背景。",
            "tone": "温和、鼓励、务实、具体；先肯定努力，再给出小动作。",
            "daily_morning_need": "每天上午给一句不空泛的鼓励，提醒用户适度休息和运动不是偷懒，而是长期表现的一部分。",
            "avoid": ["羞辱", "恐吓", "和别人比较", "只说好好学习", "把休息描述成懈怠"],
            "must_include": ["上午鼓励话语", "久坐活动策略", "压力降噪", "睡眠恢复", "今日最小行动计划"],
        },
    }
    user_text = "请生成适合 Apple Watch 展示的结构化健康报告：\n" + json.dumps(user_prompt, ensure_ascii=False, indent=2)
    client = OpenAI(api_key=api_key, base_url=openai_base_url(), timeout=300)

    if wire_api in {"chat", "chat_completions", "chat_completions_create", "chat_completions_api"}:
        text = call_chat_completions(client=client, model=model, user_text=user_text)
    else:
        text = call_responses(client=client, model=model, user_text=user_text, effort=effort, store=not disable_response_storage)

    return parse_report_json(text, metrics)


def call_responses(client: OpenAI, model: str, user_text: str, effort: str, store: bool) -> str:
    request_body = dict(
        model=model,
        input=[
            {"role": "system", "content": [{"type": "input_text", "text": SYSTEM_PROMPT}]},
            {"role": "user", "content": [{"type": "input_text", "text": user_text}]},
        ],
        reasoning={"effort": effort},
        store=store,
        max_output_tokens=2048,
    )

    try:
        response = client.responses.create(**request_body)
    except Exception as error:
        message = str(error)
        if "reasoning" in message.lower():
            request_body.pop("reasoning", None)
            response = client.responses.create(**request_body)
        elif "max_output_tokens" in message.lower():
            request_body.pop("max_output_tokens", None)
            response = client.responses.create(**request_body)
        else:
            if "524" in message or "timeout" in message.lower() or "timed out" in message.lower():
                request_body["reasoning"] = {"effort": "low"}
                request_body["max_output_tokens"] = 1536
                response = client.responses.create(**request_body)
            else:
                raise SystemExit(f"OpenAI responses request failed:\n{message}") from error

    text = response_output_text(response)
    if not text:
        raise SystemExit("OpenAI response did not contain output text")
    return text.strip()


def call_chat_completions(client: OpenAI, model: str, user_text: str) -> str:
    request_body = dict(
        model=model,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_text},
        ],
        temperature=0,
    )

    try:
        response = client.chat.completions.create(**request_body)
    except Exception as error:
        message = str(error)
        if "temperature" in message.lower():
            request_body.pop("temperature", None)
            response = client.chat.completions.create(**request_body)
        else:
            raise SystemExit(f"OpenAI chat request failed:\n{message}") from error

    text = chat_output_text(response)
    if not text:
        raise SystemExit("OpenAI chat response did not contain output text")
    return text


def response_to_dict(response) -> dict:
    if isinstance(response, dict):
        return response
    if hasattr(response, "model_dump"):
        return response.model_dump()
    if hasattr(response, "dict"):
        return response.dict()
    return {}


def response_output_text(response) -> str:
    if isinstance(response, str):
        return response.strip()
    output_text = getattr(response, "output_text", "")
    if isinstance(output_text, str) and output_text.strip():
        return output_text.strip()
    return extract_response_text(response_to_dict(response))


def chat_output_text(response) -> str:
    if isinstance(response, str):
        return response.strip()
    return extract_chat_text(response_to_dict(response))


def extract_response_text(response: dict) -> str:
    if isinstance(response.get("output_text"), str):
        return response["output_text"].strip()

    parts = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            text = content.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts).strip()


def extract_chat_text(response: dict) -> str:
    choices = response.get("choices", [])
    if not choices:
        return ""
    message = choices[0].get("message", {})
    content = message.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        return "\n".join(item.get("text", "") for item in content if isinstance(item, dict)).strip()
    return ""


def parse_report_json(text: str, metrics: dict) -> dict:
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?|```$", "", cleaned, flags=re.MULTILINE).strip()
    match = re.search(r"\{.*\}", cleaned, flags=re.DOTALL)
    if match:
        cleaned = match.group(0)
    try:
        report = json.loads(cleaned)
    except json.JSONDecodeError:
        report = fallback_report(metrics)

    return validate_report(report, metrics)


def validate_report(report: dict, metrics: dict) -> dict:
    fallback = fallback_report(metrics)
    if not isinstance(report, dict):
        return fallback
    report.setdefault("report_date", metrics["analysis_date"])
    report.setdefault("generated_at", datetime.now(timezone.utc).isoformat())
    if not isinstance(report.get("overall"), dict):
        report["overall"] = fallback["overall"]
    for key, value in fallback["overall"].items():
        report["overall"].setdefault(key, value)
    if not isinstance(report.get("sections"), list) or not report["sections"]:
        report["sections"] = fallback["sections"]

    normalized_sections = []
    for index, section in enumerate(report["sections"]):
        if not isinstance(section, dict):
            continue
        section.setdefault("id", f"section_{index}")
        section.setdefault("title", "健康指标")
        section.setdefault("status", "数据不足")
        section.setdefault("score", 60)
        section.setdefault("metrics", [])
        section.setdefault("assessment", "数据不足，需要连续佩戴以形成趋势。")
        section.setdefault("advice", "今天先保证定时起身、补水和稳定作息。")
        normalized_sections.append(section)
    report["sections"] = normalized_sections[:8] or fallback["sections"]
    return report


def metric_value(metrics: dict, metric_id: str, default: str = "无数据") -> str:
    metric = metrics["quantities"].get(metric_id)
    if not metric or metric.get("value") is None:
        return default
    value = metric.get("value")
    unit = metric.get("unit", "")
    if metric.get("aggregation") == "average":
        return f"{value:g} {unit} 平均"
    return f"{value:g} {unit}"


def fallback_report(metrics: dict) -> dict:
    sleep = metrics["sleep"]
    sleep_hours = sleep["total_asleep_minutes"] / 60
    steps = metric_value(metrics, "steps")
    hrv = metric_value(metrics, "hrv_sdnn")
    resting_hr = metric_value(metrics, "resting_heart_rate")
    oxygen = metric_value(metrics, "oxygen_saturation")
    stood_hours = metrics["stand"]["stood_hours"]

    return {
        "report_date": metrics["analysis_date"],
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "overall": {
            "score": 70,
            "title": "稳住节奏，照顾恢复",
            "assessment": "你已经在持续投入中推进今天，先用睡眠、活动和短休息保护长期表现。",
            "recommendation": "上午先完成一个最小任务，再起身走5分钟；休息不是偷懒，是让身体和大脑继续工作的燃料。",
        },
        "sections": [
            {
                "id": "morning_encouragement",
                "title": "上午鼓励",
                "status": "稳定",
                "score": 80,
                "metrics": [
                    {"label": "今天的提醒", "value": "你不需要靠焦虑证明自己在努力"},
                    {"label": "最低目标", "value": "先推进一个小问题"},
                ],
                "assessment": "进展不一定每天都立刻可见，稳定行动、恢复和复盘同样是有效投入。",
                "advice": "今天允许自己用稳定节奏开始：一段专注、一次走动、一点休息，已经是认真生活。",
            },
            {
                "id": "sleep",
                "title": "睡眠恢复",
                "status": "稳定" if sleep_hours >= 6.5 else "注意",
                "score": 75 if sleep_hours >= 6.5 else 58,
                "metrics": [
                    {"label": "总睡眠", "value": f"{sleep_hours:.1f} 小时"},
                    {"label": "深睡", "value": f"{sleep['deep_minutes']:.0f} 分钟"},
                    {"label": "REM", "value": f"{sleep['rem_minutes']:.0f} 分钟"},
                ],
                "assessment": "睡眠是恢复精力和专注的重要指标，重点看总时长、深睡和清醒次数。",
                "advice": "睡前30分钟离开高刺激任务；没完成的事情可以明天继续，不需要把压力带上床。",
            },
            {
                "id": "cardio",
                "title": "心血管与压力",
                "status": "数据不足" if hrv == "无数据" else "稳定",
                "score": 68,
                "metrics": [
                    {"label": "静息心率", "value": resting_hr},
                    {"label": "HRV", "value": hrv},
                    {"label": "心率", "value": metric_value(metrics, "heart_rate")},
                ],
                "assessment": "久坐和持续脑力负荷会让心率与 HRV 更容易受压力影响。",
                "advice": "卡住时先离座走5分钟再回来；这不是逃避，是给大脑减负。",
            },
            {
                "id": "activity",
                "title": "活动与久坐",
                "status": "注意",
                "score": 62,
                "metrics": [
                    {"label": "步数", "value": steps},
                    {"label": "站立小时", "value": f"{stood_hours} 小时"},
                    {"label": "活动能量", "value": metric_value(metrics, "active_energy")},
                ],
                "assessment": "久坐人群的主要风险是低强度长时坐姿，而不是单次运动不足。",
                "advice": "把番茄钟改成50/5：每50分钟站立、走动、拉伸髋屈肌和胸椎。",
            },
            {
                "id": "respiration",
                "title": "呼吸与血氧",
                "status": "数据不足" if oxygen == "无数据" else "稳定",
                "score": 70,
                "metrics": [
                    {"label": "血氧", "value": oxygen},
                    {"label": "呼吸频率", "value": metric_value(metrics, "respiratory_rate")},
                ],
                "assessment": "这些指标适合结合睡眠质量和疲劳感一起看，单日波动不宜过度解读。",
                "advice": "午后困倦时先做2分钟慢呼吸，再决定是否咖啡。",
            },
            {
                "id": "focus_plan",
                "title": "科研节奏",
                "status": "注意",
                "score": 72,
                "metrics": [
                    {"label": "身份场景", "value": metrics.get("persona", "久坐办公或学习")},
                    {"label": "目标", "value": "少一点自责，多一点推进"},
                ],
                "assessment": "健康策略应服务于长期稳定表现，而不是短期硬扛。",
                "advice": "今天安排2段专注、1次快走、3次拉伸；只要问题向前挪了一点，就算有效。",
            },
            {
                "id": "rest_balance",
                "title": "劳逸结合",
                "status": "稳定",
                "score": 76,
                "metrics": [
                    {"label": "休息定位", "value": "恢复不是偷懒"},
                    {"label": "建议动作", "value": "午后15-20分钟快走"},
                ],
                "assessment": "长期目标更像马拉松，持续可恢复的节奏比把自己逼到透支更重要。",
                "advice": "如果今天压力偏高，先把任务缩小到可完成的一步，然后安心休息一会儿。",
            },
        ],
    }


def markdown_from_report(report: dict) -> str:
    overall = report["overall"]
    lines = [
        f"# {report['report_date']} 健康报告",
        "",
        f"**{overall['title']}**（{overall['score']}/100）",
        "",
        overall["assessment"],
        "",
        f"建议：{overall['recommendation']}",
        "",
    ]
    for section in report["sections"]:
        lines.extend(
            [
                f"## {section['title']} · {section['status']} · {section['score']}/100",
                section["assessment"],
                f"建议：{section['advice']}",
                "",
            ]
        )
    lines.append(f"_Generated at {report['generated_at']} by GitHub Actions._")
    return "\n".join(lines) + "\n"


def encrypt_report(report: dict) -> str:
    key_text = os.environ.get("HEALTH_REPORT_KEY", "")
    try:
        key = base64.b64decode(key_text, validate=True)
    except Exception as error:
        raise SystemExit("Missing or invalid HEALTH_REPORT_KEY secret; expected base64-encoded 32-byte AES key") from error
    if len(key) != 32:
        raise SystemExit("Invalid HEALTH_REPORT_KEY secret; expected 32 bytes after base64 decoding")

    plaintext = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8")
    nonce = secrets.token_bytes(12)
    ciphertext_and_tag = AESGCM(key).encrypt(nonce, plaintext, None)
    return json.dumps(
        {
            "version": 1,
            "algorithm": "AES-256-GCM",
            "combined": base64.b64encode(nonce + ciphertext_and_tag).decode("ascii"),
        },
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n"


def main():
    args = parse_args()
    payload = load_payload(args.event)
    metrics = summarize_metrics(payload)
    report = call_openai(payload, metrics)

    report_date = report["report_date"]
    out_dir = Path(args.out_dir)
    data_dir = Path(args.data_dir)
    report_dir = Path(args.report_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    data_dir.mkdir(parents=True, exist_ok=True)
    report_dir.mkdir(parents=True, exist_ok=True)

    report_path = report_dir / f"{report_date}.json.enc"
    summary_path = out_dir / f"{report_date}.private.md"

    report_path.write_text(encrypt_report(report), encoding="utf-8")
    summary_path.write_text(markdown_from_report(report), encoding="utf-8")

    print(f"Wrote {report_path}")
    print(f"Wrote {summary_path} for workflow diagnostics only; it is not committed.")


if __name__ == "__main__":
    main()
