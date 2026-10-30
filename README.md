# COU-EYE 소스

USB 복제 검증 기록에 저장된 SHA256과 일치하는 `1.3.11-nvml7-simple4` 소스를 추출한 저장소입니다. 기본 USB 부팅에서 CPU, RAM, 메인보드, GPU, 저장장치 사양을 표시하며, DeepPE 정밀 증거 수집 코드를 함께 포함합니다.

## 구성

- `COU-EYE/`: PowerShell·CMD 실행 코드, C# 원본, 테스트, DB 열 구조
- `scripts/Build-OwnedTools.ps1`: 포함된 C# 코드 3개 빌드
- `SOURCE_MANIFEST.csv`: 원본 검증 해시와 추출 파일 해시. `HEADER_ONLY`는 장비 데이터 등을 제외하고 CSV 헤더만 남긴 파일입니다.
- `VALIDATION.md`: 추출본 검증 범위
- `DEPENDENCIES.md`: 제외한 외부 구성요소 및 배포 권리 확인 사항

## 빌드

Windows x64의 .NET Framework 4.x C# 컴파일러가 필요합니다. 저장소 루트에서 다음을 실행합니다. 실행 정책을 우회하지 말고 조직 정책에 맞는 환경을 사용하세요.

```powershell
.\scripts\Build-OwnedTools.ps1
```

이 명령은 DarkControls.dll, SpdEngine.dll, NvmlProbe.exe만 빌드합니다. WinPE 이미지 생성, 드라이버 설치, USB 초기화 또는 실제 장비 검사는 수행하지 않습니다.

## 실행 환경 준비

이 압축은 **소스용이며 바로 부팅 가능한 USB 패키지가 아닙니다.** WinPE, 드라이버, 폰트, 외부 도구 및 식별 데이터베이스를 별도로 준비해야 합니다. 빈 DB로는 기존 USB와 동일한 제조사·모델 식별 범위를 재현할 수 없습니다. 자세한 항목은 DEPENDENCIES.md를 확인하세요.

`SpdEngine.cs`는 이미 확보된 SPD 덤프의 해석기입니다. 하드웨어에서 SPD를 직접 읽는 수집 엔진이 포함됐다는 뜻이 아닙니다.

기존 테스트는 개발 단계별 가정을 포함하며, 일부 Self_Test 항목은 최신 simple4의 기본 부팅 흐름과 다를 수 있습니다. 테스트 실행 시 임시 작업본을 사용하세요. 실제 NVML, ROM 수집, DeepPE 전환 및 화면 표시는 대상 장비에서 별도로 검증해야 합니다.

## 안전 및 공개 범위

`Architecture/Prepare_USB_DualPartition.ps1`은 대상 USB를 초기화하는 관리 도구입니다. 내용과 대상 디스크를 확인하기 전에는 실행하지 마세요. DeepPE 준비·복귀 스크립트 역시 부팅 이미지와 상태를 변경할 수 있습니다.

실제 검사 로그, 결과, 장비별 등록 정보, 시리얼 목록, 드라이버, WIM/VHDX, 외부 실행 파일은 포함하지 않았습니다. CSV는 빈 스키마입니다. 공개 전 소유자가 코드 및 의존성의 배포 권리를 최종 확인해야 합니다. 이 추출 작업은 라이선스를 새로 부여하거나 GitHub에 업로드하지 않습니다.
