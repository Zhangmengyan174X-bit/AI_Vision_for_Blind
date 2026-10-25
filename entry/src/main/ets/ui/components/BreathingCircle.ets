import { AppColors } from '../AppTheme'

@Component
export struct BreathingCircle {
  @State private coreScale: number = 1.0
  @State private coreOpacity: number = 0.92
  @State private haloOpacity: number = 0.16
  @State private rippleScale: number = 1.0
  @State private rippleOpacity: number = 0.26

  aboutToAppear(): void {
    // 核心圆 + 光晕：同节奏呼吸
    this.getUIContext().animateTo({
      duration: 1800,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.coreScale = 1.08
      this.coreOpacity = 1.0
      this.haloOpacity = 0.06
    })

    // 外层涟漪：延迟 400ms，错开节奏持续向外扩散
    setTimeout(() => {
      this.getUIContext().animateTo({
        duration: 1800,
        curve: Curve.EaseOut,
        iterations: -1,
        playMode: PlayMode.Normal
      }, () => {
        this.rippleScale = 1.45
        this.rippleOpacity = 0
      })
    }, 400)
  }

  build() {
    Stack() {
      // ① 最外层：扩散涟漪
      Column()
        .width(150)
        .height(150)
        .backgroundColor(AppColors.sage)
        .borderRadius(75)
        .opacity(this.rippleOpacity)
        .scale({ x: this.rippleScale, y: this.rippleScale })

      // ② 中层：浅绿光晕
      Column()
        .width(150)
        .height(150)
        .backgroundColor(AppColors.sage)
        .borderRadius(75)
        .opacity(this.haloOpacity)
        .scale({ x: this.coreScale, y: this.coreScale })

      // ③ 内层：品牌核心（径向渐变 + 投影）
      Column()
        .width(116)
        .height(116)
        .borderRadius(58)
        .radialGradient({
          center: [40, 36],
          radius: 62,
          colors: [
            [AppColors.sageLight, 0.0],
            [AppColors.sage, 0.55],
            [AppColors.sageDeep, 1.0]
          ]
        })
        .opacity(this.coreOpacity)
        .scale({ x: this.coreScale, y: this.coreScale })
        .shadow({ radius: 26, color: 'rgba(99, 145, 138, 0.45)', offsetX: 0, offsetY: 12 })

      Text('探步')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.white)
        .letterSpacing(2)
    }
    .width(190)
    .height(190)
  }
}