# 시작하기 — UNIVERSE 360

이 패키지는 게임 소스가 아니라 Codex와 Claude Code용 개발 명세 및 지시서입니다.

1. Windows에 Godot 4 안정판과 Git을 준비합니다. https://godotengine.org/download/windows/ 및 https://git-scm.com/download/win
2. 개인 프로젝트 폴더(예: `C:\Projects\Universe360`)를 만들고 이 ZIP의 Markdown 파일들을 넣습니다. Git 저장소를 초기화하고 최초 문서 커밋을 만듭니다. 기존 저장소가 있다면 초기화 대신 상태를 확인합니다.
3. Codex에 TASK_CODEX.md의 A0 명령을 입력합니다. G0 결과를 확인한 뒤 G0 변경을 main에 반영합니다(사용자 승인). 작업트리는 깨끗해야 합니다.
4. 같은 저장소라도 두 AI가 동일 작업 폴더를 동시에 편집하지 않게 합니다. G0가 main에 반영된 상태에서 아래처럼 별도 worktree를 사용합니다. 이미 같은 브랜치/폴더가 존재하면 명령을 재실행하지 말고 기존 상태를 확인합니다.

```powershell
# Universe360 저장소 루트에서 실행
 git worktree add ../Universe360-nav -b feat/navigation main
 git worktree add ../Universe360-colony -b feat/colony main
```

5. Codex는 Universe360-nav 폴더를 열어 A1, Claude Code는 Universe360-colony 폴더를 열어 B1을 수행합니다. 두 AI 모두 공통 문서를 읽도록 지시합니다. 작업이 끝나면 각자의 변경과 테스트를 커밋하도록 요청합니다.
6. 두 작업을 검토한 후 원본 폴더에서 통합용 브랜치를 만들고 Codex에 A2를 지시합니다. 자동 병합이 충돌하면 강제 덮어쓰기 금지. main 병합 전 실제 게임을 직접 실행해 확인합니다.

```powershell
 git switch -c integration/mvp main
 # 검토 및 승인된 브랜치만 병합
 git merge --no-ff feat/navigation
 git merge --no-ff feat/colony
```

7. 최종 테스트 후 Windows 실행 파일을 받아 실행합니다. GitHub 원격 저장소는 선택사항이며 초기 개발에는 필요 없습니다.

파일 안내: MVP_SPEC.md(제품·수용기준), CONTRACT.md(공통 인터페이스), AGENTS.md(공통 규칙), TASK_CODEX.md, TASK_CLAUDE.md. Claude Code가 AGENTS.md를 자동으로 읽는다고 가정하지 말고 명시적으로 읽으라고 지시하세요.

주의: 명세는 제안이며 게임 밸런스·성능·엔진 버전은 아직 실제 검증하지 않았습니다. 첫 목표는 화려한 그래픽이 아니라 플레이 가능한 완결된 루프입니다.
