@Component
export struct SettingsPage {
  @Consume('pageStack') pageStack: NavPathStack

  build() {
    Column() {
      Text('探步')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor('#30363A')
        .margin({ top: 40 })

      Text('设置与帮助')
        .fontSize(18)
        .fontColor('#667085')
        .margin({ top: 8 })

      Blank()

      Button('开始识别')
        .width('82%')
        .height(80)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
        .backgroundColor('#63918A')
        .borderRadius(24)
        .onClick(() => {
          this.pageStack.pushPath({ name: 'CameraPage' })
        })
        .margin({ bottom: 20 })

      Button('使用说明')
        .width('82%')
        .height(70)
        .fontSize(22)
        .fontColor('#63918A')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(20)
        .onClick(() => {
          this.pageStack.clear()
        })
        .margin({ bottom: 20 })

      Button('设置')
        .width('82%')
        .height(70)
        .fontSize(22)
        .fontColor('#63918A')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(20)

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#D5D9D5')
    .alignItems(HorizontalAlign.Center)
  }
}