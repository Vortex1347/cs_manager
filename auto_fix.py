#!/usr/bin/env python3
"""
Hook: PostToolUse — автофикс багов
Если Claude написал/изменил .gd файл и в нём есть очевидные проблемы,
хук добавляет инструкцию в контекст: "найди и почини сам, не спрашивай".
"""

import sys
import os
import json
import re

def check_gd_file(path):
    issues = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
            lines = content.splitlines()
    except Exception:
        return issues

    for i, line in enumerate(lines, 1):
        stripped = line.strip()

        # Ссылка на ноду без проверки null
        if ".get_node(" in stripped and "if " not in stripped and "null" not in stripped:
            issues.append(f"Строка {i}: get_node() без проверки на null — нода может не существовать")

        # connect() старый синтаксис Godot 3
        if re.search(r'\.connect\s*\(\s*"', stripped):
            issues.append(f"Строка {i}: старый синтаксис connect() из Godot 3 — используй signal.connect(callable)")

        # move_and_slide() с аргументом (Godot 3 стиль)
        if re.search(r'move_and_slide\s*\(.+\)', stripped):
            issues.append(f"Строка {i}: move_and_slide() в Godot 4 не принимает аргументы — velocity задаётся через self.velocity")

        # NavigationAgent без ожидания готовности
        if "NavigationAgent3D" in stripped and "await" not in stripped and "get_node" in stripped:
            issues.append(f"Строка {i}: NavigationAgent3D нужно инициализировать после ready, используй await get_tree().physics_frame")

        # yield() — Godot 3
        if stripped.startswith("yield("):
            issues.append(f"Строка {i}: yield() не работает в Godot 4 — используй await")

        # onready var без $ и без get_node — возможно пропущен @onready
        if "onready" in stripped and not stripped.startswith("@onready"):
            issues.append(f"Строка {i}: возможно пропущен @ перед onready")

    return issues

def main():
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input", {})

    if tool_name not in ("Write", "Edit", "MultiEdit"):
        sys.exit(0)

    file_path = tool_input.get("file_path", "")
    if not file_path.endswith(".gd"):
        sys.exit(0)

    issues = check_gd_file(file_path)

    if issues:
        issues_text = "\n".join(f"- {i}" for i in issues)
        # Выводим в stdout — Claude Code добавит это в контекст как системное сообщение
        print(json.dumps({
            "type": "system_message",
            "message": (
                f"В файле `{file_path}` найдены потенциальные баги:\n{issues_text}\n\n"
                "Исправь их прямо сейчас в том же файле. Не спрашивай подтверждения. "
                "После правки коротко напиши что именно поменял."
            )
        }))

    sys.exit(0)

if __name__ == "__main__":
    main()
