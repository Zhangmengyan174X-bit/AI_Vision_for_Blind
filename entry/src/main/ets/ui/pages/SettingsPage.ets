import { AppColors, PAGE_GRADIENT } from '../AppTheme'

@Component
export struct SettingsPage {
  build() {
    Column() {
      Text('探步')
        .fontSize(34)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.ink)
        .letterSpacing(2)
        .margin({ top: 18 })

      Text('设置与帮助')
        .fontSize(16)
        .fontColor(AppColors.ink)
        .margin({ top: 8 })

      Blank()

      // 主行动按钮
      Button('开始识别')
        .width('86%')
        .height(76)
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.white)
        .backgroundColor(AppColors.sage)
        .borderRadius(22)
        .shadow(AppColors.shadowButton)
        .margin({ bottom: 18 })

      // 次级入口：暖白描边风格
      Button('使用说明')
        .width('86%')
        .height(66)
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.ink)
        .backgroundColor(AppColors.card)
        .borderRadius(20)
        .border({ width: 1, color: AppColors.line })
        .shadow(AppColors.shadowCard)
        .margin({ bottom: 18 })

      Button('设置')
        .width('86%')
        .height(66)
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColors.ink)
        .backgroundColor(AppColors.card)
        .borderRadius(20)
        .border({ width: 1, color: AppColors.line })
        .shadow(AppColors.shadowCard)

      Blank()

      Text('看见环境，听见世界')
        .fontSize(14)
        .fontColor(AppColors.mist)
        .margin({ bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    .alignItems(HorizontalAlign.Center)
  }
}