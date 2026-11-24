# UNIVERSE 360

실제 천문학 데이터를 바탕으로 우주를 탐험하고 문명을 발전시키는 게임입니다. 이 브랜치는 A0 개발 빌드입니다. 한국어 시작 화면에서 지구 궤도 세션을 열고, 게임 배속과 일시정지를 조작하고, 로컬 저장과 복원을 시험할 수 있습니다.

## 설치와 실행

검증 환경은 Windows x64, **Godot 4.7.2 Standard** (`4.7.2.stable.official.ed1daf0bf`), GDScript, Forward+입니다. 두 개발 브랜치에서 같은 엔진을 사용합니다. Windows x86_64 ZIP을 내려받아 기본 실행 파일과 콘솔 실행 파일을 같은 폴더에 풉니다. Godot Engine은 MIT 라이선스입니다. [Godot 4.7.2 릴리스](https://godotengine.org/download/archive/4.7.2-stable/) · [Godot 라이선스](https://godotengine.org/license/)

저장소 루트에서 다음 PowerShell 명령을 실행합니다. 에디터에서는 `project.godot`을 가져온 뒤 F5를 눌러도 됩니다.

```powershell
$godot = 'C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe'
& $godot --version
& $godot --path .
```

메뉴는 마우스 또는 Tab과 Enter로 조작합니다. 세션에서 Esc는 일시정지 또는 재개입니다. 저장은 `user://save_v1.json`에 기록하며, 그 직전의 정상 파일은 `user://save_v1.json.bak`에 보관합니다. Windows 기본 경로는 `%APPDATA%\Universe360`입니다. 저장이 손상되면 정상 백업을 선택해 불러올 수 있습니다.

## 테스트

```powershell
& $godot --headless --path . --script res://tests/core/run.gd
```

러너는 성공 시 0, 실패 시 1을 반환합니다. GUI 실행과 프로세스 재시작 검증 명령은 [A0 검증 기록](docs/a0-verification.md)에 있습니다. 테스트는 임시 저장 경로를 사용합니다.

## 모듈 계약

| 위치 | 역할 |
| --- | --- |
| `src/contracts/schema.gd` | 상태 및 기지 초기값, 명령 결과, 저장 스키마 검증 |
| `src/core/` | 상태 스냅샷, 고정 tick, 명령 라우터, JSON 저장 및 복원 |
| `src/contracts/mocks/` | 카탈로그, 항법, 기지 계약의 독립 실행용 구현 |
| `scenes/main/` | 시작 화면과 세션 UI, 어댑터 조립 |
| `tests/core/` | 코어 및 시작 화면 검증 |

Main이 어댑터를 연결합니다. Router에 의존성을 주입하면 각 모듈을 상대 모듈의 스텁과 실행할 수 있습니다. UI는 Router에 명령을 보내고 분리된 상태 스냅샷을 받습니다. Router는 매 tick마다 항법, 기지, tick 증가, 상태 변경 이벤트 순으로 처리합니다. 배속은 1×·10×·60×입니다. 프레임마다 최대 120 tick을 처리하고 초과분은 다음 프레임으로 넘깁니다.

G0에서 사용하는 천체 이름과 관계는 테스트 fixture입니다. 물리 수치는 비워 두었으며 관측 자료나 외부 자산을 포함하지 않습니다. 시작 화면의 궤도 그림은 자체 제작한 도형입니다. 좌표와 데이터 출처 규칙은 [MVP_SPEC.md](MVP_SPEC.md)와 [CONTRACT.md](CONTRACT.md)에 있습니다.

## 다음 브랜치

GitHub의 `feat/g0-platform`은 G0 검토 브랜치입니다. G0 승인 후 두 모듈을 동일한 G0 커밋에서 별도 worktree로 시작합니다. 기존 브랜치가 있으면 `git worktree list`와 `git branch --all`로 먼저 확인합니다.

```powershell
git fetch origin
git worktree add -b feat/navigation ../Universe360-nav origin/feat/g0-platform
git worktree add -b feat/colony ../Universe360-colony origin/feat/g0-platform
```

1. `feat/navigation`에서 [TASK_CODEX.md](TASK_CODEX.md)의 A1을 실행합니다.
2. `feat/colony`에서 [TASK_CLAUDE.md](TASK_CLAUDE.md)의 B1을 병렬 실행합니다. 각 모듈의 독립 테스트 결과를 자체 PR에 기록합니다.
3. 두 모듈 PR 검토 후 통합 담당이 A2에서 어댑터와 씬을 실제 구현으로 교체하고 통합 테스트와 Windows export를 진행합니다.

공유 파일 소유권과 변경 절차는 [AGENTS.md](AGENTS.md) 및 [CONTRACT.md](CONTRACT.md)를 따릅니다.
