import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { requestCameraPermission } from '../entryability/PermissionHelper';
import { SpeechManager } from '../utils/SpeechManager';
import { YoloDetector, DetectedObject } from '../utils/YoloDetector';
import { BreathingCircle } from '../ui/components/BreathingCircle';
import { sensor } from '@kit.SensorServiceKit';
import { vibrator } from '@kit.SensorServiceKit';
import { preferences } from '@kit.ArkData';
import { AppColors, PAGE_GRADIENT } from '../ui/AppTheme';

@Entry
@Component
struct Index {
  @Provide('pageStack') pageStack: NavPathStack = new NavPathStack()
  @State private promptOpacity: number = 0
  @State private promptOffset: number = 20
  @State private speechSpeed: string = '标准'
  @State private vibrationEnabled: boolean = true
  @State private voiceHintEnabled: boolean = true

  private xComponentController: XComponentController = new XComponentController();
  private cameraManager: camera.CameraManager | null = null;
  private cameraInput: camera.CameraInput | null = null;
  private previewOutput: camera.PreviewOutput | null = null;
  private captureSession: camera.Session | null = null;
  private previewSurfaceId: string = '';
  private imageReceiver: image.ImageReceiver | null = null;
  private receiverSurfaceId: string = '';
  private lastDetectTime: number = 0;
  private detectInterval: number = 800;
  private isDetecting: boolean = false;
  private yoloDetector: YoloDetector | null = null;
  private sensorCallback: ((data: sensor.GyroscopeResponse) => void) | null = null;
  @State isPreviewing: boolean = false;

  private isPhoneStable: boolean = true;
  private lastObjectState: Map<string, Map<string, number>> = new Map();
  private lastSpokenText: string = '';
  private lastSpeakTime: number = 0;

  onObjectDetected(objects: DetectedObject[]): void {
    if (objects.length === 0) return;

    // 1. 过滤掉常见误识别物品，以及太小的噪点
    const ignoreLabels = ['冰箱', '电视', '微波炉', '烤箱', '床', '马桶', '水槽'];
    objects = objects.filter(obj => {
      const isIgnored = ignoreLabels.includes(obj.label);
      const isTooSmall = (obj.box.width * obj.box.height) < 0.03;

      // 【防反光】过滤掉长宽比极其奇怪的框（比如细长的反光）
      const aspectRatio = obj.box.width / obj.box.height;
      const isWeirdShape = aspectRatio > 3 || aspectRatio < 0.33;

      return !isIgnored && !isTooSmall && !isWeirdShape;
    });

    if (objects.length === 0) return;

    const now = Date.now();

    let highestThreatObj: DetectedObject | null = null;
    let highestThreatScore = -1;
    let finalSpeech = '';
    let isDanger = false;

    for (let i = 0; i < objects.length; i++) {
      const obj = objects[i];
      const currentArea = obj.box.width * obj.box.height;
      const centerX = obj.box.left + obj.box.width / 2;

      let positionStr = '正前方';
      if (centerX < 0.33) positionStr = '左前方';
      else if (centerX > 0.67) positionStr = '右前方';

      // 置信度是基础分（0~100分），面积只作为微调（最多加 20 分）
      let threatScore = obj.score * 100 + currentArea * 20;
      let objIsDanger = false;
      let statusStr = '';

      const distanceStr = currentArea > 0.15 ? '' : '远处';

      const lastState = this.lastObjectState.get(obj.label);
      if (lastState && this.isPhoneStable) {
        const timeDiff = now - (lastState.get('time') || 0);
        if (timeDiff > 0 && timeDiff < 800) {
          const lastArea = lastState.get('area') || 0.01;
          const areaGrowthRate = (currentArea - lastArea) / lastArea;

          if (areaGrowthRate > 0.4) {
            threatScore += 200;
            objIsDanger = true;
            statusStr = '有快速冲过来的';
          } else if (areaGrowthRate > 0.1) {
            threatScore += 50;
            statusStr = '有正在靠近的';
          }
        }
      }

      const isVehicle = ['汽车', '自行车', '摩托车', '公交车', '卡车'].includes(obj.label);
      if (obj.label === '人' || isVehicle) {
        threatScore += 30;
      }

      const stateMap = new Map<string, number>();
      stateMap.set('area', currentArea);
      stateMap.set('time', now);
      this.lastObjectState.set(obj.label, stateMap);

      if (threatScore > highestThreatScore) {
        highestThreatScore = threatScore;
        highestThreatObj = obj;

        let dodgeDir = '停步';
        if (centerX < 0.33) dodgeDir = '向右躲';
        else if (centerX > 0.67) dodgeDir = '向左躲';

        if (objIsDanger) {
          finalSpeech = `警告！${positionStr}，${dodgeDir}！${statusStr}${obj.label}`;
          isDanger = true;
        } else if (statusStr) {
          finalSpeech = `${distanceStr}${positionStr}${statusStr}${obj.label}`;
        } else {
          finalSpeech = `${distanceStr}${positionStr}有${obj.label}`;
        }
      }
    }

    if (highestThreatObj) {
      // 1.5 秒内同样的东西不重复报
      if (finalSpeech === this.lastSpokenText && (now - this.lastSpeakTime < 1500)) {
        return;
      }

      console.info(`[TTS播报] ${finalSpeech} (危险状态: ${isDanger})`);

      // 【核心优化：只在必要时打断】
      const isCompletelyNew = !finalSpeech.includes(this.lastSpokenText) && !this.lastSpokenText.includes(finalSpeech);

      if (isDanger || isCompletelyNew) {
        SpeechManager.getInstance().stop();
        setTimeout(() => {
          SpeechManager.getInstance().speak(finalSpeech);
        }, 50);
      } else {
        SpeechManager.getInstance().speak(finalSpeech);
      }

      this.lastSpokenText = finalSpeech;
      this.lastSpeakTime = now;
    }
  }  // ← 这个是闭合 onObjectDetected 方法的！

  aboutToAppear(): void {
    SpeechManager.getInstance().init();
    this.startWelcomeAnimation();
    this.inspectNNRT();
    this.initGyroscope();

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;

    this.checkPrivacy(context)

    this.yoloDetector = new YoloDetector(context);
    this.yoloDetector.loadModel().then((success: boolean) => {
      if (success) {
        console.info('YOLO 模型加载成功');
      } else {
        console.error('YOLO 模型加载失败');
      }
    });

    requestCameraPermission(context).then((granted) => {
      if (!granted) {
        console.error('权限未授予');
      }
    });
  }

  private startWelcomeAnimation(): void {
    this.promptOpacity = 0
    this.promptOffset = 20
    setTimeout(() => {
      this.getUIContext().animateTo({
        duration: 1000,
        curve: Curve.EaseOut
      }, () => {
        this.promptOpacity = 1
        this.promptOffset = 0
      })
    }, 700)
  }

  private initGyroscope(): void {
    try {
      this.sensorCallback = (data: sensor.GyroscopeResponse) => {
        const angularVelocity = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);

        // 【照妖镜】：只要摇手机，控制台就会疯狂刷这行
        console.info(`[陀螺仪] 当前角速度: ${angularVelocity.toFixed(2)}, 手机平稳: ${this.isPhoneStable}`);

        if (angularVelocity > 0.8) {
          this.isPhoneStable = false;
        } else {
          this.isPhoneStable = true;
        }
      };
      sensor.on(sensor.SensorId.GYROSCOPE, this.sensorCallback, { interval: 100000000 });
      console.info('陀螺仪传感器已启动');
    } catch (error) {
      console.error('陀螺仪启动失败: ' + JSON.stringify(error));
    }
  }

  private inspectNNRT(): void {
    try {
      const devices = mindSporeLite.getAllNNRTDeviceDescriptions();
      console.info(`[NNRT] device count = ${devices.length}`);
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[NNRT] enumeration failed: code=${err.code}, message=${err.message}`);
    }
  }

  aboutToDisappear(): void {
    SpeechManager.getInstance().shutdown();
    this.releaseCamera();
    if (this.yoloDetector) {
      this.yoloDetector.release();
      this.yoloDetector = null;
    }
    if (this.sensorCallback) {
      sensor.off(sensor.SensorId.GYROSCOPE, this.sensorCallback);
    }
  }

  async initCamera(): Promise<void> {
    if (!this.previewSurfaceId) {
      console.error('SurfaceId 未就绪');
      return;
    }

    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.cameraManager = camera.getCameraManager(context);

      const cameras = this.cameraManager.getSupportedCameras();
      const backCamera = cameras.find(
        cam => cam.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK
      ) || cameras[0];

      if (!backCamera) {
        console.error('未找到可用相机');
        return;
      }

      this.cameraInput = this.cameraManager.createCameraInput(backCamera);
      await this.cameraInput.open();

      const outputCapability = this.cameraManager.getSupportedOutputCapability(
        backCamera, camera.SceneMode.NORMAL_PHOTO
      );

      let previewProfile = outputCapability.previewProfiles[0];
      for (let i = 1; i < outputCapability.previewProfiles.length; i++) {
        const p = outputCapability.previewProfiles[i];
        if (p.size.width * p.size.height > previewProfile.size.width * previewProfile.size.height) {
          previewProfile = p;
        }
      }
      console.info(`选中的预览尺寸: ${previewProfile.size.width}x${previewProfile.size.height}`);

      this.previewOutput = this.cameraManager.createPreviewOutput(
        previewProfile, this.previewSurfaceId
      );

      const receiverSize: image.Size = {
        width: previewProfile.size.width,
        height: previewProfile.size.height
      };

      this.imageReceiver = image.createImageReceiver(
        receiverSize, image.ImageFormat.JPEG, 8
      );
      this.receiverSurfaceId = await this.imageReceiver.getReceivingSurfaceId();

      this.imageReceiver.on('imageArrival', () => {
        this.imageReceiver?.readNextImage((err: BusinessError, nextImage: image.Image) => {
          if (err || !nextImage) {
            console.error(`读取图像失败: ${err?.code}`);
            return;
          }

          const now = Date.now();
          if (now - this.lastDetectTime < this.detectInterval) {
            nextImage.release();
            return;
          }
          if (this.isDetecting) {
            nextImage.release();
            return;
          }
          this.lastDetectTime = now;
          this.isDetecting = true;

          this.detectObject(nextImage).finally(() => {
            this.isDetecting = false;
            nextImage.release();
          });
        });
      });

      const receiverOutput = this.cameraManager.createPreviewOutput(
        previewProfile, this.receiverSurfaceId
      );

      this.captureSession = this.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.Session;
      this.captureSession.beginConfig();
      this.captureSession.addInput(this.cameraInput);
      this.captureSession.addOutput(this.previewOutput);
      this.captureSession.addOutput(receiverOutput);
      await this.captureSession.commitConfig();
      await this.captureSession.start();

      this.isPreviewing = true;
      console.info('相机会话启动成功');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`相机初始化失败: code=${e.code}, message=${e.message}`);
    }
  }

  async releaseCamera(): Promise<void> {
    try {
      if (this.imageReceiver) {
        this.imageReceiver.off('imageArrival');
        await this.imageReceiver.release();
        this.imageReceiver = null;
      }
      if (this.captureSession) {
        await this.captureSession.stop();
        await this.captureSession.release();
        this.captureSession = null;
      }
      if (this.previewOutput) {
        await this.previewOutput.release();
        this.previewOutput = null;
      }
      if (this.cameraInput) {
        await this.cameraInput.close();
        this.cameraInput = null;
      }
      this.isPreviewing = false;
      console.info('相机已释放');
    } catch (err) {
      const e = err as BusinessError;
      console.error(`释放失败: ${e.code} ${e.message}`);
    }
  }

  async detectObject(img: image.Image): Promise<void> {
    if (this.yoloDetector === null) {
      console.error('YOLO 检测器未初始化');
      return;
    }

    let imageSource: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;

    try {
      const component = await img.getComponent(image.ComponentType.JPEG);
      if (!component || !component.byteBuffer) {
        console.error('获取图像数据失败');
        return;
      }

      const realWidth = img.size.width;
      const realHeight = img.size.height;

      const sourceOptions: image.SourceOptions = {
        sourcePixelFormat: image.PixelMapFormat.NV21,
        sourceSize: {
          width: realWidth,
          height: realHeight
        },
        sourceDensity: 120
      };

      imageSource = image.createImageSource(component.byteBuffer, sourceOptions);
      if (!imageSource) {
        console.error('创建 ImageSource 失败');
        return;
      }

      pixelMap = await imageSource.createPixelMap();

      const inputData: Float32Array = await this.preprocessImage(pixelMap);
      if (!inputData || inputData.length === 0) {
        console.error('preprocessImage 返回空数据');
        return;
      }

      const objects: DetectedObject[] = await this.yoloDetector.detect(inputData);

      if (objects.length > 0) {
        console.info(`YOLO 识别到 ${objects.length} 个目标`);
        this.onObjectDetected(objects);
      } else {
        console.info('YOLO 未识别到目标');
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`识别失败: code=${e.code}, message=${e.message}`);
    } finally {
      if (pixelMap) {
        pixelMap.release();
      }
      if (imageSource) {
        imageSource.release();
      }
    }
  }

  private async preprocessImage(pixelMap: image.PixelMap): Promise<Float32Array> {
    const INPUT_SIZE = 640;
    const defaultResult = new Float32Array(1 * 3 * INPUT_SIZE * INPUT_SIZE);

    try {
      const info = pixelMap.getImageInfoSync();
      if (!info || !info.size) {
        console.error('getImageInfoSync 返回空');
        return defaultResult;
      }

      const scaleX = INPUT_SIZE / info.size.width;
      const scaleY = INPUT_SIZE / info.size.height;
      await pixelMap.scale(scaleX, scaleY);

      const buffer = new ArrayBuffer(INPUT_SIZE * INPUT_SIZE * 4);
      await pixelMap.readPixelsToBuffer(buffer);
      const rgba = new Uint8Array(buffer);

      // NHWC 布局
      const float32 = new Float32Array(1 * INPUT_SIZE * INPUT_SIZE * 3);
      for (let i = 0; i < INPUT_SIZE * INPUT_SIZE; i++) {
        float32[i * 3] = rgba[i * 4] / 255.0;
        float32[i * 3 + 1] = rgba[i * 4 + 1] / 255.0;
        float32[i * 3 + 2] = rgba[i * 4 + 2] / 255.0;
      }
      return float32;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`预处理失败: code=${e.code}, message=${e.message}`);
      return defaultResult;
    }
  }

  private enterRecognition(): void {
    this.vibrate(60)
    this.pageStack.pushPath({ name: 'CameraPage' })
  }
  private openHelp(): void {
    this.pageStack.pushPath({ name: 'Help' })
  }
  private openVoiceSettings(): void {
    this.pageStack.pushPath({ name: 'VoiceSettings' })
  }
  private backToSettings(): void {
    this.pageStack.pop()
  }

  private vibrate(duration: number): void {
    if (!this.vibrationEnabled) {
      return;
    }
    try {
      vibrator.startVibration({ type: 'time', duration: duration }, { usage: 'notification' });
      console.info(`[振动] startVibration 成功，时长=${duration}ms`);
    } catch (err) {
      console.error('[振动] startVibration 失败: ' + JSON.stringify(err));
      try {
        vibrator.vibrate(duration);
        console.info('[振动] 已回退到 vibrate() 旧接口');
      } catch (e2) {
        console.error('[振动] vibrate() 也失败: ' + JSON.stringify(e2));
      }
    }
  }

  private privacyContext: common.UIAbilityContext | null = null
  private privacyController: CustomDialogController | null = null

  private checkPrivacy(context: common.UIAbilityContext): void {
    try {
      this.privacyContext = context
      const prefs = preferences.getPreferencesSync(context, { name: 'app_settings' })
      const agreed = prefs.getSync('privacyAgreed', false) as boolean
      if (agreed) {
        return; // 已同意过，不再弹出
      }
      this.privacyController = new CustomDialogController({
        builder: PrivacyDialog({
          onAgree: () => { this.markPrivacyAgreed() },
          onDisagree: () => { this.exitApp() }
        }),
        customStyle: true,
        alignment: DialogAlignment.Center,
        autoCancel: false // 不允许点击空白处关闭，必须做出选择
      })
      // 延迟半秒弹出，等首页渲染完成
      setTimeout(() => {
        this.privacyController?.open()
      }, 500)
    } catch (err) {
      console.error('隐私政策检查失败: ' + JSON.stringify(err));
    }
  }

  private markPrivacyAgreed(): void {
    try {
      if (!this.privacyContext) {
        return;
      }
      const prefs = preferences.getPreferencesSync(this.privacyContext, { name: 'app_settings' })
      prefs.putSync('privacyAgreed', true)
      prefs.flush()
      console.info('隐私政策：用户已同意');
    } catch (err) {
      console.error('保存隐私政策状态失败: ' + JSON.stringify(err));
    }
  }

  private exitApp(): void {
    try {
      this.privacyContext?.terminateSelf()
    } catch (err) {
      console.error('退出应用失败: ' + JSON.stringify(err));
    }
  }

  private speakHelpPage(): void {
    if (!this.voiceHintEnabled) {
      return;
    }
    const helpText: string = '使用说明。简单三步开始使用。' +
      '第一步，打开应用，启动探步后，应用进入待机模式。' +
      '第二步，轻触屏幕任意位置，即可进入识别模式。' +
      '第三步，听取语音提示，应用会识别环境并通过语音告诉你周围的目标。' +
      '退出识别：在识别页面点击退出识别按钮，即可返回设置与帮助页面。';
    SpeechManager.getInstance().speak(helpText);
  }

  // ============================================================
  //  相机识别页：深色悬浮层 + 底部渐变压暗，保证任何画面下可读
  // ============================================================
  @Builder
  buildCameraPage() {
    NavDestination() {
      Stack() {

        XComponent({
          id: 'camera_preview',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .width('100%')
          .height('100%')
          .renderFit(RenderFit.RESIZE_COVER)
          .onLoad(() => {
            this.previewSurfaceId = this.xComponentController.getXComponentSurfaceId();
            this.initCamera();
          })
          .accessibilityText('相机取景画面')

        Column() {
          // 顶部状态胶囊：墨底 + 亮青状态点
          Row() {
            // 状态点（容器圆，兼容全版本）
            Column()
              .width(10)
              .height(10)
              .backgroundColor(AppColors.sageLight)
              .borderRadius(5)
            Text('正在识别中')
              .fontSize(15)
              .fontColor(AppColors.white)
              .margin({ left: 8 })
          }
          .backgroundColor(AppColors.overlay)
          .padding({ left: 16, right: 18, top: 9, bottom: 9 })
          .borderRadius(20)
          .margin({ top: 54 })
          .accessibilityGroup(true)

          Blank()

          // 底部：渐变压暗 + 大触控退出按钮
          Column() {
            Button('退出识别')
              .width('100%')
              .height(72)
              .fontSize(24)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.white)
              .backgroundColor(AppColors.overlayDeep)
              .borderRadius(36)
              .border({ width: 1, color: 'rgba(255, 255, 255, 0.22)' })
              .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.28)', offsetX: 0, offsetY: 8 })
              .onClick(() => {
                this.vibrate(60)
                this.pageStack.replacePath({ name: 'Settings' });
              })
              .accessibilityText('退出识别，返回设置页面')
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 72, bottom: 34 })
          .linearGradient({
            angle: 180,
            colors: [
              ['rgba(48, 54, 58, 0)', 0.0],
              ['rgba(48, 54, 58, 0.55)', 1.0]
            ]
          })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
  }

  build() {
    Navigation(this.pageStack) {
      this.buildWelcomePage()
    }
    .navDestination(this.PageMap)
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
  }

  @Builder
  PageMap(name: string) {
    if (name === 'CameraPage') {
      this.buildCameraPage()
    } else if (name === 'Settings') {
      this.buildSettingsPage()
    } else if (name === 'Help') {
      this.buildHelpPage()
    } else if (name === 'VoiceSettings') {
      this.buildVoiceSettingsPage()
    }
  }

  // ============================================================
  //  欢迎页：渐变背景 + 装饰圆 + 呼吸圆 + 入场动效
  // ============================================================
  @Builder
  buildWelcomePage() {
    NavDestination() {
      Stack() {
        // 背景装饰圆（极低透明度，增加层次）
        // 背景装饰圆（容器圆，兼容全版本）
        Column()
          .width(280)
          .height(280)
          .backgroundColor(AppColors.sage)
          .borderRadius(140)
          .opacity(0.07)
          .position({ x: '-25%', y: '-8%' })
        Column()
          .width(220)
          .height(220)
          .backgroundColor(AppColors.sageDeep)
          .borderRadius(110)
          .opacity(0.06)
          .position({ x: '72%', y: '76%' })

        Column() {
          Column() {
            Text('探步')
              .fontSize(40)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.ink)
              .letterSpacing(4)
            Text('智能视觉辅助')
              .fontSize(16)
              .fontColor(AppColors.ink)
              .letterSpacing(6)
              .margin({ top: 10 })
          }
          .margin({ top: 52 })

          Blank()

          BreathingCircle()

          Blank()

          Column() {
            Text('轻触屏幕任意位置')
              .fontSize(24)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColors.ink)
            Text('开始识别')
              .fontSize(28)
              .fontColor(AppColors.sage)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 10 })
          }
          .opacity(this.promptOpacity)
          .translate({ y: this.promptOffset })

          // 底部能力说明胶囊
          Row() {
            Column()
              .width(8)
              .height(8)
              .backgroundColor(AppColors.sage)
              .borderRadius(4)
            Text('环境感知 · 语音辅助')
              .fontSize(14)
              .fontColor(AppColors.ink)
              .margin({ left: 8 })
          }
          .padding({ left: 18, right: 18, top: 10, bottom: 10 })
          .backgroundColor('rgba(246, 247, 244, 0.65)')
          .borderRadius(22)
          .opacity(this.promptOpacity)
          .margin({ top: 30, bottom: 44 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 28, right: 28 })
        .onClick(() => {
          this.vibrate(60)
          this.pageStack.pushPath({ name: 'CameraPage' })
        })
        .accessibilityText('轻触屏幕任意位置，开始识别')
      }
      .width('100%')
      .height('100%')
      .linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }
    .hideTitleBar(true)
  }

  // ============================================================
  //  设置与帮助首页：统一卡片语言（暖白卡 + 柔和投影）
  // ============================================================
  @Builder
  buildSettingsPage() {
    NavDestination() {
      Scroll() {
        Column() {
          // 顶部品牌区
          Row() {
            Column() {
              Text('探步')
                .fontSize(34)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.ink)
                .letterSpacing(2)
              Text('设置与帮助')
                .fontSize(16)
                .fontColor(AppColors.ink)
                .margin({ top: 6 })
            }
            .alignItems(HorizontalAlign.Start)

            Blank()
          }
          .width('100%')
          .margin({ top: 44 })

          // 主行动卡：开始识别
          Column() {
            Row() {
              Text('开始使用')
                .fontSize(13)
                .fontColor(AppColors.ink)
                .letterSpacing(3)
              Blank()
            }
            .width('100%')

            Button('开始识别')
              .width('100%')
              .height(76)
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.white)
              .backgroundColor(AppColors.sage)
              .borderRadius(22)
              .shadow(AppColors.shadowButton)
              .margin({ top: 16 })
              .onClick(() => { this.enterRecognition() })
              .accessibilityText('开始识别')
          }
          .width('100%')
          .padding(22)
          .backgroundColor(AppColors.card)
          .borderRadius(24)
          .shadow(AppColors.shadowCard)
          .margin({ top: 32 })

          // 入口卡：使用说明
          this.buildEntryCard('说', '使用说明', '了解如何开始识别、退出识别以及使用语音辅助', () => { this.openHelp() })

          // 入口卡：语音设置
          this.buildEntryCard('语', '语音设置', `当前语速：${this.speechSpeed}`, () => { this.openVoiceSettings() })

          // 无障碍能力卡（浅青底）
          Column() {
            Row() {
              Text('无障碍设计')
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.ink)
              Blank()
              Text('已启用')
                .fontSize(13)
                .fontColor(AppColors.sageDeep)
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .backgroundColor('rgba(99, 145, 138, 0.14)')
                .borderRadius(12)
            }
            .width('100%')

            Text('大触控区域 · 语音反馈 · 振动提示')
              .fontSize(15)
              .fontColor(AppColors.ink)
              .margin({ top: 10 })

            Divider()
              .strokeWidth(0.5)
              .color(AppColors.line)
              .margin({ top: 16, bottom: 14 })

            Row() {
              Text(this.vibrationEnabled ? '振动提示：开启' : '振动提示：关闭')
                .fontSize(15)
                .fontColor(AppColors.sageDeep)
              Blank()
              Text('点击设置')
                .fontSize(14)
                .fontColor(AppColors.mist)
            }
            .width('100%')
            .onClick(() => { this.openVoiceSettings() })
          }
          .width('100%')
          .padding(22)
          .backgroundColor(AppColors.sageSoft)
          .borderRadius(24)
          .margin({ top: 18 })
          .accessibilityGroup(true)

          // 页脚
          Column() {
            Text('探步')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.sage)
              .letterSpacing(2)
            Text('看见环境，听见世界')
              .fontSize(14)
              .fontColor(AppColors.mist)
              .margin({ top: 6 })
          }
          .margin({ top: 36, bottom: 40 })
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .width('100%')
      .height('100%')
      .linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }
    .hideTitleBar(true)
  }

  /** 通用入口卡：左侧首字徽标 + 标题/副标题 + 箭头 */
  @Builder
  buildEntryCard(mark: string, title: string, subtitle: string, onTap: () => void) {
    Row() {
      Stack() {
        Column()
          .width(48)
          .height(48)
          .backgroundColor(AppColors.sageSoft)
          .borderRadius(24)
        Text(mark)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.sageDeep)
      }

      Column() {
        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.ink)
        Text(subtitle)
          .fontSize(14)
          .fontColor(AppColors.ink)
          .margin({ top: 6 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 16 })

      Text('›')
        .fontSize(28)
        .fontColor(AppColors.mist)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(AppColors.card)
    .borderRadius(24)
    .shadow(AppColors.shadowCard)
    .margin({ top: 18 })
    .onClick(onTap)
    .accessibilityGroup(true)
    .accessibilityText(title + '，' + subtitle)
  }

  // ============================================================
  //  使用说明页
  // ============================================================
  @Builder
  buildHelpPage() {
    NavDestination() {
      Scroll() {
        Column() {
          // 返回栏
          Row() {
            Stack() {
              Column()
                .width(44)
                .height(44)
                .backgroundColor(AppColors.card)
                .borderRadius(22)
              Text('‹')
                .fontSize(26)
                .fontColor(AppColors.ink)
                .margin({ bottom: 4 })
            }
            .shadow(AppColors.shadowCard)
            .onClick(() => { this.backToSettings() })
            .accessibilityText('返回上一页')

            Text('使用说明')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.ink)
              .margin({ left: 14 })
            Blank()
          }
          .width('100%')
          .margin({ top: 40 })

          Text('简单三步开始使用')
            .fontSize(16)
            .fontColor(AppColors.ink)
            .width('100%')
            .margin({ top: 12, bottom: 24 })

          this.buildHelpCard('01', '打开应用', '启动探步后，应用进入待机模式。')
          this.buildHelpCard('02', '轻触屏幕任意位置', '即可进入识别模式。')
          this.buildHelpCard('03', '听取语音提示', '应用会识别环境并通过语音告诉你周围的目标。')

          // 退出说明卡
          Column() {
            Row() {
              Stack() {
                Column()
                  .width(48)
                  .height(48)
                  .backgroundColor(AppColors.sageSoft)
                  .borderRadius(24)
                Text('退')
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColors.sageDeep)
              }
              Column() {
                Text('退出识别')
                  .fontSize(19)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColors.ink)
                Text('在识别页面点击“退出识别”，返回设置与帮助页面。')
                  .fontSize(15)
                  .fontColor(AppColors.ink)
                  .margin({ top: 7 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 16 })
            }
            .width('100%')
          }
          .width('100%')
          .padding(20)
          .backgroundColor(AppColors.card)
          .borderRadius(24)
          .shadow(AppColors.shadowCard)
          .margin({ top: 4, bottom: 40 })
          .accessibilityGroup(true)
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
      }
      .width('100%')
      .height('100%')
      .linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }
    .hideTitleBar(true)
    .onShown(() => {
      this.speakHelpPage()
    })
    .onHidden(() => {
      SpeechManager.getInstance().stop()
    })
  }

  @Builder
  buildHelpCard(number: string, title: string, description: string) {
    Row() {
      Stack() {
        Column()
          .width(52)
          .height(52)
          .backgroundColor(AppColors.sageSoft)
          .borderRadius(26)
        Text(number)
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.sageDeep)
      }
      .width(56)
      .height(56)

      Column() {
        Text(title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.ink)
        Text(description)
          .fontSize(15)
          .fontColor(AppColors.ink)
          .margin({ top: 7 })
      }
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 16 })
      .layoutWeight(1)
    }
    .width('100%')
    .padding(20)
    .backgroundColor(AppColors.card)
    .borderRadius(24)
    .shadow(AppColors.shadowCard)
    .margin({ bottom: 14 })
    .accessibilityGroup(true)
  }

  // ============================================================
  //  语音设置页：分段选择器 + 系统开关
  // ============================================================
  @Builder
  buildVoiceSettingsPage() {
    NavDestination() {
      Column() {
        // 返回栏
        Row() {
          Stack() {
            Column()
              .width(44)
              .height(44)
              .backgroundColor(AppColors.card)
              .borderRadius(22)
            Text('‹')
              .fontSize(26)
              .fontColor(AppColors.ink)
              .margin({ bottom: 4 })
          }
          .shadow(AppColors.shadowCard)
          .onClick(() => { this.backToSettings() })
          .accessibilityText('返回上一页')

          Text('语音设置')
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColors.ink)
            .margin({ left: 14 })
          Blank()
        }
        .width('100%')
        .margin({ top: 40 })

        // 播报速度：分段选择器
        Column() {
          Row() {
            Text('播报速度')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColors.ink)
            Blank()
            Text(`当前：${this.speechSpeed}`)
              .fontSize(14)
              .fontColor(AppColors.sageDeep)
          }
          .width('100%')

          Row() {
            this.buildSpeedButton('慢')
            this.buildSpeedButton('标准')
            this.buildSpeedButton('快')
          }
          .width('100%')
          .padding(4)
          .backgroundColor(AppColors.sageSoft)
          .borderRadius(20)
          .margin({ top: 18 })
        }
        .width('100%')
        .padding(22)
        .backgroundColor(AppColors.card)
        .borderRadius(24)
        .shadow(AppColors.shadowCard)
        .margin({ top: 30 })

        // 反馈开关卡：振动 + 语音
        Column() {
          Row() {
            Column() {
              Text('振动提示')
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.ink)
              Text(this.vibrationEnabled ? '进入和退出识别时提供振动反馈' : '振动反馈已关闭')
                .fontSize(14)
                .fontColor(AppColors.ink)
                .margin({ top: 7 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.vibrationEnabled })
              .selectedColor(AppColors.sage)
              .switchPointColor(AppColors.white)
              .accessibilityText('振动提示开关')
              .onChange((isOn: boolean) => {
                this.vibrationEnabled = isOn
                if (isOn) {
                  this.vibrate(60)
                }
              })
          }
          .width('100%')

          Divider()
            .strokeWidth(0.5)
            .color(AppColors.line)
            .margin({ top: 18, bottom: 18 })

          Row() {
            Column() {
              Text('语音提示')
                .fontSize(19)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColors.ink)
              Text(this.voiceHintEnabled ? '进入和退出识别时播放语音提示' : '语音提示已关闭')
                .fontSize(14)
                .fontColor(AppColors.ink)
                .margin({ top: 7 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.voiceHintEnabled })
              .selectedColor(AppColors.sage)
              .switchPointColor(AppColors.white)
              .accessibilityText('语音提示开关')
              .onChange((isOn: boolean) => { this.voiceHintEnabled = isOn })
          }
          .width('100%')
        }
        .width('100%')
        .padding(22)
        .backgroundColor(AppColors.card)
        .borderRadius(24)
        .shadow(AppColors.shadowCard)
        .margin({ top: 18 })

        Blank()

      }
      .width('100%')
      .height('100%')
      .padding({ left: 24, right: 24 })
      .linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }
    .hideTitleBar(true)
  }

  @Builder
  buildSpeedButton(speed: string) {
    Button(speed)
      .layoutWeight(1)
      .height(52)
      .fontSize(17)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.speechSpeed === speed ? AppColors.white : AppColors.sageDeep)
      .backgroundColor(this.speechSpeed === speed ? AppColors.sage : Color.Transparent)
      .borderRadius(16)
      .shadow(this.speechSpeed === speed
        ? { radius: 10, color: 'rgba(99, 145, 138, 0.35)', offsetX: 0, offsetY: 4 }
        : { radius: 0, color: Color.Transparent })
      .onClick(() => {
        this.speechSpeed = speed
        SpeechManager.getInstance().setSpeed(speed)
      })
      .accessibilityText('语速' + speed + (this.speechSpeed === speed ? '，当前已选中' : ''))
  }
}

@CustomDialog
struct PrivacyDialog {
  controller?: CustomDialogController
  onAgree: () => void = () => {}
  onDisagree: () => void = () => {}

  build() {
    Column() {
      Text('隐私政策')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColors.ink)

      Text('探步为纯离线应用：所有图像识别与语音处理均在本机完成，不收集、不上传、不共享任何个人信息。相机画面仅用于实时识别，不会保存。')
        .fontSize(15)
        .fontColor(AppColors.ink)
        .lineHeight(24)
        .margin({ top: 14 })

      // ★★★ 请把下面的链接替换为你在华为后台生成的隐私政策地址 ★★★
      Text('查看完整《隐私政策》')
        .fontSize(15)
        .fontColor(AppColors.sageDeep)
        .margin({ top: 12 })
        .accessibilityText('查看完整隐私政策链接')
        .onClick(() => {
          const privacyUrl: string = 'https://github.com/Zhangmengyan174X-bit/tanbu-privacy/blob/main/privacy.md'
          try {
            const ctx = this.privacyContext as common.UIAbilityContext
            ctx.openLink(privacyUrl)
          } catch (err) {
            console.error('打开隐私政策链接失败: ' + JSON.stringify(err));
          }
        })

      Row() {
        Button('不同意并退出')
          .layoutWeight(1)
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColors.ink)
          .backgroundColor(AppColors.sageSoft)
          .borderRadius(14)
          .accessibilityText('不同意并退出应用')
          .onClick(() => {
            this.controller?.close()
            this.onDisagree()
          })

        Blank().width(12)

        Button('同意并继续使用')
          .layoutWeight(1)
          .height(48)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColors.white)
          .backgroundColor(AppColors.sage)
          .borderRadius(14)
          .shadow(AppColors.shadowButton)
          .accessibilityText('同意隐私政策，继续使用')
          .onClick(() => {
            this.controller?.close()
            this.onAgree()
          })
      }
      .width('100%')
      .margin({ top: 24 })
    }
    .width('86%')
    .padding(24)
    .backgroundColor(AppColors.card)
    .borderRadius(24)
    .shadow(AppColors.shadowCard)
  }

  // @CustomDialog 内获取上下文（供打开链接使用）
  private get privacyContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext
  }
}
