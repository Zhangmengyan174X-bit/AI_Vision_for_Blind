import { BreathingCircle } from '../components/BreathingCircle'

@Component
export struct RecognitionPage {
  build() {
    Stack() {
      Column() {
        Text('正在识别环境')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1F2933')
          .margin({ top: 80 })

        BreathingCircle()

        Text('语音辅助已开启')
          .fontSize(18)
          .fontColor('#667085')
          .margin({ top: 35 })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#E8F1EF')
  }
}