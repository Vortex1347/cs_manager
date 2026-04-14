#!/usr/bin/env python3
"""
Hook: post-file-write
Запускается после каждого создания/изменения .gd или .tscn файла.
Проверяет базовые ошибки и напоминает о правилах проекта.
"""

import sys
import os
import json

def main():
    # Читаем событие от Claude Code (stdin)
    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)

    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input", {})

    # Реагируем только на запись файлов
    if tool_name not in ("Write", "Edit", "MultiEdit"):
        sys.exit(0)

    file_path = tool_input.get("file_path", "")

    # Проверяем только GDScript и сцены
    if not (file_path.endswith(".gd") or file_path.endswith(".tscn")):
        sys.exit(0)

    issues = []

    if file_path.endswith(".gd"):
        try:
            with open(file_path, "r", encoding="utf-8") as f:
                content = f.read()
                lines = content.split("\n")

            # Нет комментария в начале файла
            if not lines[0].startswith("#"):
                issues.append(f"⚠️  {file_path}: первая строка должна быть комментарием — что делает файл")

            # Магические числа (простая эвристика)
            magic_number_lines = []
            for i, line in enumerate(lines, 1):
                stripped = line.strip()
                # Ищем числа не в @export и не в константах
                if ("= " in stripped and 
                    not stripped.startswith("#") and
                    not stripped.startswith("const ") and
                    not stripped.startswith("@export") and
                    not "Color" in stripped):
                    import re
                    if re.search(r'=\s*\d{2,}', stripped):
                        magic_number_lines.append(i)
            
            if magic_number_lines:
                issues.append(f"⚠️  {file_path}: возможные магические числа на строках {magic_number_lines[:3]} — используй константы или @export")

        except Exception:
            pass

    # Выводим предупреждения если есть
    if issues:
        output = {
            "continue": True,
            "suppressOutput": False,
            "decision": "continue_with_message" if issues else "continue"
        }
        for issue in issues:
            print(issue, file=sys.stderr)
    
    sys.exit(0)

if __name__ == "__main__":
    main()
