# A1 태양계 항법

## 실행

Windows x64와 Godot 4.7.2 Standard (`4.7.2.stable.official.ed1daf0bf`)를 사용합니다. 저장소 루트에서 `$godot`에 Godot 콘솔 실행 파일 경로를 지정합니다.

```powershell
& $godot --path . res://scenes/navigation/navigation_demo.tscn
& $godot --headless --path . --script res://tests/navigation/run.gd
& $godot --headless --path . --script res://tests/core/run.gd
```

천체를 지도에서 클릭하거나 목록으로 선택합니다. 우클릭 드래그는 카메라 회전, 휠은 확대 및 축소입니다. 지도 위에서 A·D로 우주선 방향을 바꾸고 W·S로 기동 표시를 움직입니다. Space로 기동 표시를 정지합니다. 목적지까지 상태를 전환할 때는 자동 항법을 사용합니다. Esc로 일시정지와 재개를 전환합니다.

달은 연료 5와 게임 시간 20초, 화성은 연료 20과 게임 시간 60초가 필요합니다. 도착 후 착륙하고 표면 상태에서 이륙할 수 있습니다. 항법 시연의 저장 슬롯은 `user://navigation_demo_v1.json`입니다.

## 데이터와 좌표

- 태양과 8행성, 달의 반지름과 질량, 공전 장반경은 공개 수치입니다. 행성 공전 장반경은 JPL 표 1의 au에 IAU 정의값 149,597,870.7 km를 곱해 km 단위로 반올림했습니다. 지구는 지구·달 질량중심 장반경을 근사값으로 사용합니다. 태양과 달의 질량은 GM/G로 환산했습니다. [NASA/JPL Planetary Physical Parameters](https://ssd.jpl.nasa.gov/planets/phys_par.html) · [Approximate Positions of the Planets](https://ssd.jpl.nasa.gov/planets/approx_pos.html) · [Astrodynamic Parameters](https://ssd.jpl.nasa.gov/astro_par.html) · [NASA Solar Radius](https://science.nasa.gov/universe/glossary/) · [JPL Satellite Physical Parameters](https://ssd.jpl.nasa.gov/sats/phys_par/)
- 원형 공전 모델은 J2000부터 게임 시간 초 단위로 진행합니다. 행성 초기 위상에는 JPL 평균 경도, 달에는 평균 근점이각·근점 인수·승교점 경도의 합을 사용합니다. 위치와 거리는 64비트 스칼라의 km 값으로 계산합니다. 화면의 궤도와 천체 크기에는 별도 축척을 적용합니다. [JPL Planetary Satellite Mean Elements](https://ssd.jpl.nasa.gov/sats/elem/)
- 프록시마 센타우리, 바너드별, 시리우스는 태양 기준 광년 목록에서 탐색할 수 있습니다. 확인한 필드와 출처를 표시하고, 근거를 채택하지 않은 반지름과 질량은 자료 없음으로 둡니다. [NASA Sun Facts](https://science.nasa.gov/sun/facts/) · [ESA 연구 보고서 표 1](https://www.esa.int/gsp/ACT/doc/ARI/ARI%20Study%20Report/ACT-RPT-MAD-ARI-03-4102b-InterstellarTravels-Padova.pdf)
- 출처 확인일과 이용 메모를 `data/catalog/bodies.json`에 넣었습니다. JPL SSD 수치 자료는 퍼블릭 도메인입니다. 지도와 표식은 Godot 기본 메시로 제작했습니다. [NASA/JPL SSD 이용 조건](https://ssd.jpl.nasa.gov/faq.html)

## 통합 의존성

`Catalog`를 생성해 `Navigation`의 생성자에 전달합니다. `NavigationView.attach(catalog, router.dispatch)`로 UI를 연결하고 Router의 `state_changed`에서 `NavigationView.show_state(snapshot)`을 호출합니다. 독립 데모는 이 연결과 G0 기지 스텁을 사용합니다. A2의 export에는 `data/catalog/*.json`을 포함해야 합니다.

표면 씬 전환, 착륙·이륙 자동 저장, 실제 기지 생산, 통합 오프라인 플레이와 Windows 배포 검증은 A2에서 진행합니다.

## 검증 결과

| 실행 | 결과 |
| --- | --- |
| A1 헤드리스 검사 | 53개 통과, 종료 코드 0 |
| A1 Windows GUI 검사 및 화면 캡처 | 54개 통과, 종료 코드 0 |
| G0 헤드리스 회귀 검사 | 61개 통과, 종료 코드 0 |

Windows의 RTX 4090에서 Vulkan Forward+로 지도 실행과 화면 캡처를 확인했습니다. 검사에는 좌표 축척, 카탈로그 유효성 및 출처, 목록과 지도 클릭, 휠 확대, 초기 상태, 달·화성 발진과 착륙·이륙, 연료 부족, 가스·얼음 거대행성 착륙 거절, 비행 중 및 착륙 후 저장 복원이 포함됩니다.
