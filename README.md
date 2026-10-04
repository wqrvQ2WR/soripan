# 소리판 (Soripan)

macOS용 멀티트랙 오디오 편집기. SwiftUI + AVFoundation, 외부 의존성 없음.

## 다운로드

[Releases](https://github.com/wqrvQ2WR/soripan/releases/latest)에서 `Soripan-x.y.z.zip`을 받아 압축을 풀고 `Soripan.app`을 응용 프로그램 폴더로 옮기면 됨. macOS 14 이상, 애플 실리콘/인텔 모두 지원.

공증(notarize)을 받지 않은 앱이라 처음 열 때 "확인되지 않은 개발자" 경고가 뜸. 아래 둘 중 하나로 열면 됨.

- Finder에서 앱을 우클릭 → 열기 → 열기 (안 되면 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기")
- 터미널: `xattr -dr com.apple.quarantine /Applications/Soripan.app`

## 기능

- 멀티트랙 타임라인: 클립 이동(트랙 간 이동 포함, 가장자리/재생헤드 스냅), 양끝 끌어서 트림, 페이드 인/아웃 핸들
- 재생헤드에서 자르기, 복제, 삭제, 노멀라이즈, 클립 게인
- 클립별 피치(±12반음)와 배속(0.5x~2x), 서로 독립적으로 적용 (AVAudioUnitTimePitch 오프라인 렌더)
- 트랙 볼륨, 팬, 뮤트, 솔로
- 마이크 녹음: 선택한 트랙의 재생헤드 위치에 녹음, 다른 트랙을 들으면서 녹음 가능. 파일은 `~/Music/소리판 녹음/`
- WAV(16bit) / M4A(AAC 256k) 믹스다운 내보내기
- 프로젝트 저장/불러오기 (`.soripan`, JSON). 오디오 경로를 절대+상대 경로로 저장해서 폴더째 옮겨도 열림
- 실행 취소/다시 실행, 재생헤드 따라 페이지 스크롤, 빈 곳 끌어서 화면 이동

## 단축키

| 키 | 동작 |
|---|---|
| Space | 재생 / 일시정지 |
| S | 재생헤드에서 자르기 |
| Delete | 선택 클립 삭제 |
| R | 녹음 시작 / 중지 |
| ⌘D | 복제 |
| ⌘Z / ⇧⌘Z | 실행 취소 / 다시 실행 |
| ⌘N / ⌘O / ⌘S / ⇧⌘S | 새 프로젝트 / 열기 / 저장 / 다른 이름으로 저장 |
| ⌘I | 오디오 가져오기 |
| ⌘E / ⇧⌘E | WAV / M4A로 내보내기 |
| ⌘= / ⌘- | 확대 / 축소 |

## 빌드

macOS 14 이상, Xcode 명령줄 도구(Swift 5.9+) 필요.

```bash
./build_app.sh              # Soripan.app 생성 (유니버설 바이너리, ad-hoc 서명)
ditto Soripan.app /Applications/Soripan.app
```

ad-hoc 서명이라 직접 빌드한 맥에서 쓰는 용도. 다른 맥에서는 Gatekeeper 경고가 뜸.

## 구조

- `Sources/Soripan/Audio.swift` 모델, 디코딩, 믹서, 피치/배속 렌더, 재생, 녹음, 프로젝트 파일 포맷
- `Sources/Soripan/Editor.swift` 편집 상태, 실행 취소, 클립 편집, 저장/불러오기
- `Sources/Soripan/Views.swift` 타임라인, 클립, 트랙 헤더, 인스펙터 UI
- `Sources/Soripan/SoripanApp.swift` 앱 진입점, 메뉴/단축키
