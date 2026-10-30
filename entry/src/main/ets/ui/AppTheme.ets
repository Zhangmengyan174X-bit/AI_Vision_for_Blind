export class AppColors {
  static readonly ink: string = '#46504C'
  static readonly paper: string = '#D5D9D5'
  static readonly sage: string = '#63918A'
  static readonly sageDeep: string = '#4F7A73'
  static readonly sageLight: string = '#8FB1AA'
  static readonly sageSoft: string = '#E4EBE8'
  static readonly card: string = '#F6F7F4'
  static readonly mist: string = '#97A19A'
  static readonly line: string = '#C8CEC7'
  static readonly white: string = '#FFFFFF'
  static readonly overlay: string = 'rgba(70, 80, 76, 0.55)'
  static readonly overlayDeep: string = 'rgba(70, 80, 76, 0.92)'
  static readonly shadowCard: ShadowOptions = {
    radius: 18, color: 'rgba(70, 80, 76, 0.08)', offsetX: 0, offsetY: 6
  }
  static readonly shadowButton: ShadowOptions = {
    radius: 16, color: 'rgba(99, 145, 138, 0.35)', offsetX: 0, offsetY: 8
  }
}

export const PAGE_GRADIENT: Array<[ResourceColor, number]> = [
  ['#DEE2DD', 0.0],
  ['#D5D9D5', 0.55],
  ['#CBD2CB', 1.0]
]