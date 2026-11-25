# B1 행성 표면·기지 모듈 (feat/colony)

기지 모듈은 `src/colony/`, `scenes/colony/`, `data/balance/`, `tests/colony/`에 있습니다. 공통 Router, Clock, SaveStore와 G0 mock navigation을 사용합니다.

Windows에서 Godot 4.7.2 Standard (`4.7.2.stable.official.ed1daf0bf`)로 검증했습니다. B1 테스트 273개가 헤드리스와 NVIDIA GeForce RTX 4090의 Vulkan Forward+ 실행에서 각각 통과했습니다. 달과 화성의 독립 화면을 실행해 이전·건설·이륙·착륙 동작을 확인했습니다.

## 파일

| 파일 | 역할 |
|---|---|
| `data/balance/colony_balance.json` | 모든 밸런스 수치(게임 가정치), 격자·노드·건물·연구·지형 파라미터 |
| `src/colony/balance.gd` | JSON 로드·검증. 정수는 `SaveJson`으로 파싱해 정수로 유지 |
| `src/colony/terrain_generator.gd` | seed 기반 512 m 구역의 노드 배치와 높이 격자 생성 |
| `src/colony/colony.gd` | CONTRACT의 `create/apply/step` + UI용 읽기 전용 도우미 |
| `scenes/colony/colony_view.tscn/.gd` | 독립 실행 가능한 3D 표면 씬과 UI |
| `tests/colony/run.gd` | headless 계약 테스트 (T05–T11 중 경제·스키마 부분) |

## 실행

```powershell
$godot = 'C:\Tools\Godot\Godot_v4.7.2-stable_win64_console.exe'
# 테스트 (종료 코드 0 = 통과, 1 = 실패)
& $godot --headless --path . --script res://tests/colony/run.gd
# 독립 씬 (달 표면에서 시작, 드롭다운으로 화성 선택)
& $godot --path . res://scenes/colony/colony_view.tscn
```

독립 씬은 G0의 `Router`와 mock navigation을 사용하며 자체적으로 고정 1초 tick을 진행합니다. 통합 시에는 `colony_view.configure(router, colony_module, colony_id)`를 호출하면 씬이 시계를 진행하지 않고 스냅샷 읽기와 `router.dispatch()` 명령 전송만 수행합니다. 이륙은 `{"type":"TAKEOFF"}`를 router에 위임하고, 성공 시 `takeoff_completed` 시그널을 냅니다.

WASD로 이동하고 Q/E 또는 우클릭 드래그로 회전합니다. 휠은 확대·축소, Shift는 빠른 이동입니다. 1–5로 시설을 선택하고 좌클릭으로 건설합니다. Esc는 선택 해제, G는 격자 표시, 표면 화면에서 Space는 일시정지입니다.

## 게임 규칙

- **지형**: 512 m × 512 m = 64 × 64 칸(8 m). 착륙대는 (32, 32) 중심 3 × 3 칸이며 건설 불가. 지형은 생성된 가상 지형이며 화면에 명시합니다.
- **seed**: `colony.seed = world_seed XOR FNV-1a32(body_id)`. 엔진의 `String.hash()`에 의존하지 않습니다. 같은 seed·generator_version·body_id → 같은 노드와 높이.
- **노드**: 광석 4 · 얼음 2 · 실리콘 2, 각 1000. 가장자리 2칸, 노드 간 4칸, 착륙대 5칸 이상 이격. id는 `d1`…`d8`.
- **채굴**: P0는 광석 노드만. 얼음·실리콘은 정보 표시용(건설 거부).
- **재고**: 기지 재고는 비어서 시작합니다. 건설 비용은 **기지 재고**에서 차감하므로 먼저 `TRANSFER`로 우주선 화물을 옮겨야 합니다. 저장 한도는 기지 전체 단위 합계(기본 100, 창고당 +100). 우주선 화물 한도 200.
- **원자성**: `apply`는 입력 state를 변경하지 않고 복사본을 반환합니다. 실패 시 원래 state와 사용자용 한국어 메시지를 돌려주며 자원은 줄지 않습니다.
- **tick**: `step`은 기지 id 오름차순, 시설은 태양광 → 채굴기 → 정제기 → 연구소, 같은 종류는 시설 id의 **숫자** 오름차순(`b9` < `b10`). 전력은 저장하지 않고 매 tick 이 순서로 배분하며, 실제로 가동하는 시설만 전력을 소모합니다. 전력·재료·저장 공간 부족 시 그 시설은 통째로 정지(부분 소비 없음). 정지 사유 우선순위: 전력 → 재료/노드 → 저장.
- **연구**: 연구소가 금속 1 → 연구 1을 생산해 `state.research`(전역)와 `colony.research`(기지 기여)에 더합니다. 해금 판단은 tick **시작 시점**의 전역 연구값으로 하므로 기지 처리 순서와 무관합니다. 20 이상이면 채굴량 +1(`mining_efficiency_1`)이 모든 기지에 적용됩니다.
- **월드 의존 없음**: `step`은 씬·우주선 위치와 무관하게 모든 기지를 갱신합니다.

## 인터페이스

```
Colony.create(body_id, world_seed) -> Dictionary
Colony.apply(state, {type:"BUILD", colony_id, building_type, grid_x, grid_y, deposit_id}) -> {ok, code, message, state}
Colony.apply(state, {type:"TRANSFER", colony_id, resource, amount, direction}) -> {ok, code, message, state}
Colony.step(state) -> Dictionary
# UI 읽기 전용
Colony.summarize(state, colony_id), placement_problem(...), cost_shortage(...), capacity_of(colony)
```

`building_type`: `solar`, `miner`, `refiner`, `warehouse`, `lab`. 채굴기는 광석 노드 칸에 `deposit_id`를 지정해야 하며(없으면 거부), 다른 시설은 노드 칸에 둘 수 없고 `deposit_id`는 `null`입니다. 시설 id는 `b<next_entity_id>`입니다.

오류 코드: `INVALID_TARGET`(알 수 없는 기지·시설·자원·수량·방향), `INVALID_PLACEMENT`, `INSUFFICIENT_RESOURCE`, `CAPACITY_EXCEEDED`, `INVALID_MODE`(해당 기지 표면이 아님), `UNKNOWN_COMMAND`, `INVALID_STATE`(밸런스 파일 로드 실패).

## 테스트 범위

| 항목 | 내용 |
|---|---|
| T05 | 동일 seed/버전/천체의 노드·높이 재현, 다른 천체·seed는 다름, 격자·간격·착륙대 조건 |
| T06 | 태양광 없는 채굴기 정지(NO_POWER), 전력 후 광석 +2/tick, 매장량 감소 |
| T07 | 채굴기+정제기 10 tick 후 금속 +10 |
| T08 | 비용 부족(부분 보유 포함)·범위 밖·착륙대·중복·잘못된 노드·저장/화물 초과·잘못된 수량 거부, state 불변 |
| 순서 | 시설 id 숫자 정렬(`b9`/`b10`), 전력 배분 |
| 연구 | 20 도달 후 채굴량 +1, 전역 해금이 모든 기지에 적용 |
| 저장/고갈 | 저장 가득 시 전체 정지, 잔량보다 적게 채굴, 창고 용량 |
| T09 | Router + mock navigation으로 달 이륙·화성 60 tick 후 달 기지가 로컬 60 tick 실행과 동일 |
| T10 | 1×/10×/60× 결과 동일, 일시정지 중 불변 |
| T11 | JSON 인코딩 및 SaveStore 파일 왕복, 복원 뒤 동일한 시뮬레이션 |
| 씬 | 씬 인스턴스화, UI 이전·건설이 router를 거쳐 상태에 반영 |

실제 Main에서의 A1/B1 연결, 씬 전환 및 자동 저장은 A2에서 검증합니다.

## 데이터·자산 출처

- 모든 수치: `MVP_SPEC.md` 4장의 초기 밸런스(게임 가정). `colony_balance.json`의 `provenance`에 `data_status: generated`로 기록.
- 지형, 자원 노드, 시설 메시는 Godot에서 절차 생성한 도형입니다. 화면에 생성 지형과 매장량을 표시합니다.

## 알려진 한계와 통합 메모

- `summarize`의 가동·정지 상태와 생산량은 **다음 tick 예측**입니다. 창고는 보관 중으로 집계합니다.
- 얼음·실리콘 사용처, 연료 생산, 자동 물류는 P1입니다.
- 독립 씬의 지형 높이는 화면용이며 건설 판정에는 쓰이지 않습니다(격자 좌표만 사용).
- `Colony.new()`는 `res://data/balance/colony_balance.json`을 읽습니다. 파일이 없거나 잘못되면 `create`는 `{}`를 반환하고 Router가 `INVALID_STATE`로 거부합니다.
- 통합 시 Main에서 `colony_view.configure()`를 호출합니다. Windows 패키지에는 `data/balance/*.json`을 포함해야 합니다.
