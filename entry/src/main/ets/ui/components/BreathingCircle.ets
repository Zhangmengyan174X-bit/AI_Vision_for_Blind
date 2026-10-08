import { deviceInfo } from "@kit.BasicServicesKit"

@Component
export struct BreathingCircle {
  @State private scaleValue: number = 1.0
  @State private opacityValue: number = 0.75

  aboutToAppear(): void {
    this.startBreathing()
  }

  private startBreathing(): void {
    this.getUIContext().animateTo({
      duration: 1800,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate
    }, () => {
      this.scaleValue = 1.12
      this.opacityValue = 1.0
    })
  }

  build() {
    Stack() {
      if (deviceInfo.apiAvailable('26.0.0')) {
        Circle()
          .width(130)
          .height(130)
          .fill('#356D73')
          .opacity(this.opacityValue)
          .scale({
            x: this.scaleValue,
            y: this.scaleValue
          })
      } else {
        Circle()
          .width(130)
          .height(130)
          .backgroundColor('#356D73')
          .fillOpacity(this.opacityValue)
          .scale({
            x: this.scaleValue,
            y: this.scaleValue
          })
      }

      if (deviceInfo.apiAvailable('26.0.0')) {
        Circle()
          .width(90)
          .height(90)
          .fill('#4E8B76')
      } else {
        Circle()
          .width(90)
          .height(90)
          .backgroundColor('#4E8B76')
      }

      Text('声视')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
    }
    .width(160)
    .height(160)
  }
}