# A0 검증 기록

Windows x64에서 Godot `4.7.2.stable.official.ed1daf0bf`로 실행했습니다. GUI 검증은 NVIDIA GeForce RTX 4090, Vulkan 1.4.341, Forward+에서 수행했습니다.

| 실행 | 결과 |
| --- | --- |
| 헤드리스 코어 및 시작 화면 테스트 | 61개 통과, 종료 코드 0 |
| Windows 기본 시작 씬 실행 | Forward+ 구동, 종료 코드 0 |
| Windows GUI 테스트와 화면 캡처 | 63개 통과, 종료 코드 0 |
| Godot 재실행 후 동일 저장 읽기 | 쓰기와 읽기 프로세스 모두 종료 코드 0 |

## 재현 명령

저장소 루트에서 실행합니다. `$godot`에는 [README](../README.md)의 Godot 콘솔 실행 파일 경로를 지정합니다.

```powershell
$qa = (New-Item -ItemType Directory -Path .godot/a0-qa -Force).FullName
& $godot --headless --path . --script res://tests/core/run.gd
& $godot --path . --quit-after 120
& $godot --path . --script res://tests/core/run.gd -- "--capture-dir=$qa"
$slot = Join-Path $qa ('restart-' + [guid]::NewGuid() + '.json')
& $godot --headless --path . --script res://tests/core/save_restart.gd -- write $slot
& $godot --headless --path . --script res://tests/core/save_restart.gd -- read $slot
```

## 검증 범위

- 시작 상태는 지구 궤도, 연료 100, 금속 50, 얼음 20, 부품 20, 연구 0입니다.
- 공통 러너로 스냅샷 격리, 스텁 명령 라우팅, 착륙 시 기지 생성 및 보존, tick 순서, 배속 일치, 일시정지, tick 상한과 잔여 시간 보존을 검사합니다.
- 저장 검사는 64비트 seed, 비행 및 기지 상태, 정상 백업, 손상된 저장, 미래 스키마 보호, 백업 및 교체 실패, 중단된 교체 복구를 포함합니다.
- Windows GUI에서는 시작 화면, 새 게임, 옵션, 배속, 일시정지, 저장, 이어하기, 백업 선택을 확인합니다. 시작 화면과 세션을 PNG로 저장합니다.
- 프로세스 재시작 검사는 서로 다른 Godot 프로세스에서 쓰기와 읽기를 실행해 저장 당시의 시간과 상태를 비교합니다.

## 미검증 항목

- 실제 관측 카탈로그, 3D 지도와 비행·착륙, 지형, 건설, 생산, 연구 자동화, 미방문 기지의 생산은 각 모듈과 A2 통합에서 검증합니다. 이 브랜치의 달·화성 상태 전환은 계약 검증용입니다.
- 착륙·이륙 자동 저장, 전체 MVP 오프라인 플레이, 1080p 5분 성능 측정, Windows 배포용 실행 파일은 A2 범위입니다.
- 동일 저장 슬롯의 동시 다중 프로세스 쓰기와 강제 전원 차단은 시험하지 않았습니다. A0 UI는 로컬 단일 세션에서 저장을 실행합니다.
