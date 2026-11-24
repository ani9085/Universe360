# 공통 기술 계약 v0.1 (G0에서 고정)

## 저장소
```
project.godot
scenes/main/           # 통합 담당
src/core/             # 통합 담당: 상태, clock, 저장, command router
src/contracts/        # 통합 담당: 타입/스키마
src/navigation/       # Codex
scenes/navigation/    # Codex
src/catalog/          # Codex
data/catalog/         # Codex
src/colony/           # Claude Code
scenes/colony/        # Claude Code
data/balance/         # Claude Code
tests/core/           # 통합 담당
tests/navigation/     # Codex
tests/colony/         # Claude Code
docs/                 # 설계 및 테스트 증거
```
G0 통합 담당(Codex 권장)은 project.godot, Main, GameState, Clock, CommandRouter, 저장 스텁과 mock catalog/colony adapter를 먼저 구현한다. 두 모듈은 이 커밋을 기반으로 분기한다. 공유 파일 수정은 통합 담당만 수행; 변경 요청은 문서와 PR로 제안한다.

## 데이터 스키마 (GDScript Dictionary/JSON)
- Body: `{id: String, parent_id: String|null, name: String, kind: String, radius_km: float|null, orbit_radius_km: float|null, distance_ly: float|null, landable: bool, provenance: Dictionary}`. ID는 `sol`, `sol.earth`, `sol.earth.moon`, `sol.mars` 등 고정값. `distance_ly`는 태양 기준 인근 항성용.
- Ship: `{body_id: String, mode: String, destination_id: String|null, travel_ticks_remaining: int, fuel: int, cargo: Dictionary, local_pose: Dictionary}`. mode=ORBIT/FLIGHT/SURFACE. local_pose는 JSON 숫자 배열 사용.
- Colony: `{id: String, body_id: String, seed: int, generator_version: int, inventory: Dictionary, capacity: int, buildings: Array, deposits: Array, research: int, upgrades: Array}`. MVP는 천체당 1기지.
- Building: `{id: String, type: String, grid_x: int, grid_y: int, deposit_id: String|null}`. Deposit: `{id: String, resource: String, remaining: int, grid_x: int, grid_y: int}`.
- State: `{schema_version: 1, world_seed: int, tick: int, speed: int, paused: bool, ship: Dictionary, colonies: Dictionary, research: int, next_entity_id: int}`. 연구 전역 해금은 state.research에 누적; colony.research는 기지별 기여량. 재고 키: ore, metal, ice, silicon, parts. 초기 부재 키는 0.

## 계약 함수
모든 명령은 Main의 router를 통해서만 실행; UI가 GameState를 직접 수정하지 않는다. 상태 스냅샷은 deep copy로 전달. 모듈은 기존 state를 복사하고 검증 후 새 state 반환; 실패 시 기존 상태 유지.
```
Catalog.get_body(id: String) -> Dictionary
Catalog.list_bodies(parent_id: String) -> Array
Navigation.apply(state: Dictionary, command: Dictionary) -> Dictionary
Navigation.step(state: Dictionary) -> Dictionary
Colony.apply(state: Dictionary, command: Dictionary) -> Dictionary
Colony.step(state: Dictionary) -> Dictionary
Colony.create(body_id: String, world_seed: int) -> Dictionary
Router.dispatch(command: Dictionary) -> Dictionary
```
apply 반환 형식 `{ok: bool, code: String, message: String, state: Dictionary}`. step은 갱신 state 반환. 성공 code=OK; 오류 예: INVALID_TARGET, NOT_ARRIVED, NOT_LANDABLE, INSUFFICIENT_FUEL, INSUFFICIENT_RESOURCE, CAPACITY_EXCEEDED, INVALID_PLACEMENT, INVALID_MODE, UNKNOWN_COMMAND. 오류 문구는 사용자 친화적으로 표시.

명령 예시:
```
{"type":"TRAVEL","body_id":"sol.earth.moon"}
{"type":"LAND","body_id":"sol.earth.moon"}
{"type":"TAKEOFF"}
{"type":"BUILD","colony_id":"sol.earth.moon","building_type":"miner","grid_x":2,"grid_y":3,"deposit_id":"d1"}
{"type":"TRANSFER","colony_id":"sol.earth.moon","resource":"metal","amount":5,"direction":"ship_to_colony"}
{"type":"SET_SPEED","speed":10}
{"type":"SET_PAUSED","paused":true}
```
TRAVEL/LAND/TAKEOFF는 Navigation 담당. LAND 성공 후 router가 Colony.create로 최초 기지 생성(기존 기지 보존); TRANSFER/BUILD는 Colony 담당, 현재 SURFACE 및 동일 body_id에서만 허용. 수동 비행은 화면 내 방향/시점 조작과 목표 접근 표현에 한정; 실제 목적지 상태 전환은 TRAVEL 명령으로 통일한다. 연료 차감은 TRAVEL 성공 시 1회. 취소 기능 P1. 기타 목적지 비용은 카탈로그 UI에 명시하고 MVP에서는 달/화성 외 비행은 지도 탐색만 허용.

## tick과 저장
Clock은 렌더링 프레임 delta를 누적하여 배속에 따른 정수 tick을 발생시킨다. 매 tick: Navigation.step → Colony.step(모든 기지, ID 정렬) → tick 증가 → state_changed 이벤트. 프레임당 처리 상한 120 tick, 잔여 누적량 보존. pause 시 추가 누적 없음. UI는 state_changed 구독 및 읽기만 수행. 스텝에서 네트워크·시스템 시각·랜덤 전역값 사용 금지.
저장 경로 `user://save_v1.json`; 임시 파일 쓰기, 유효성 검사, 기존 정상 파일 백업, 교체. 저장 실패 시 기존 파일 유지. 미래 스키마는 조용히 덮어쓰지 말고 오류 표시. 종료 중 시간 경과는 반영하지 않는다.

## 협업 원칙
각 모듈은 mock으로 독립 실행 가능해야 한다. 공통 계약은 합의 없이 변경하지 않는다. 작업 전 git status 확인, 다른 작업자 파일 덮어쓰기/강제 push/reset 금지. 테스트는 headless GDScript runner(종료 코드 0/1)로 구현하고 실행 명령을 README에 명시. 실제 GUI/Windows export 테스트는 별도 증거와 함께 보고한다.
