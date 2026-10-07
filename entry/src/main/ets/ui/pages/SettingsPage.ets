@Component
export struct SettingsPage {
  build() {
    Column() {
      Text('声视')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor('#1F2933')
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
        .backgroundColor('#356D73')
        .borderRadius(24)
        .margin({ bottom: 20 })

      Button('使用说明')
        .width('82%')
        .height(70)
        .fontSize(22)
        .fontColor('#356D73')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(20)
        .margin({ bottom: 20 })

      Button('设置')
        .width('82%')
        .height(70)
        .fontSize(22)
        .fontColor('#356D73')
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(20)

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F7F6')
    .alignItems(HorizontalAlign.Center)
  }
}