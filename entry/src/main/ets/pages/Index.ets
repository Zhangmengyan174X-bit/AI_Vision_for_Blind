import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { requestCameraPermission } from '../entryability/PermissionHelper';
import { SpeechManager } from '../utils/SpeechManager';
import { YoloDetector, DetectedObject } from '../utils/YoloDetector';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { BreathingCircle } from '../ui/components/BreathingCircle';
import { sensor } from '@kit.SensorServiceKit';

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

    // 【第一道防线】过滤掉常见误识别物品（幻觉），以及太小的噪点
    const ignoreLabels = ['冰箱', '电视', '微波炉', '烤箱', '床', '马桶', '水槽'];
    objects = objects.filter(obj => {
      const isIgnored = ignoreLabels.includes(obj.label);
      const isTooSmall = (obj.box.width * obj.box.height) < 0.03;
      return !isIgnored && !isTooSmall;
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

      let threatScore = currentArea * 100;
      let objIsDanger = false;
      let statusStr = '';

      const distanceStr = currentArea > 0.15 ? '' : '远处';

      // 判断面积暴增 (稍微调灵敏了一点)
      // 判断面积暴增 (调回 0.4 的黄金阈值)
      const lastState = this.lastObjectState.get(obj.label);
      if (lastState && this.isPhoneStable) {
        const timeDiff = now - (lastState.get('time') || 0);
        if (timeDiff > 0 && timeDiff < 800) {
          const lastArea = lastState.get('area') || 0.01;
          const areaGrowthRate = (currentArea - lastArea) / lastArea;

          // 【终极定版】超过 40% 才算冲过来
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
      // 2 秒内不重复播报同样的内容
      if (finalSpeech === this.lastSpokenText && (now - this.lastSpeakTime < 2000)) {
        return;
      }

      console.info(`[TTS播报] ${finalSpeech} (危险状态: ${isDanger})`);
      SpeechManager.getInstance().speak(finalSpeech);

      this.lastSpokenText = finalSpeech;
      this.lastSpeakTime = now;
    }
  }

  aboutToAppear(): void {
    SpeechManager.getInstance().init();
    this.startWelcomeAnimation();
    this.inspectNNRT();
    this.initGyroscope();

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;

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

  // ============ 页面跳转控制 ============
  private enterRecognition(): void {
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

        Column() {
          Row() {
            Text('● 正在识别中')
              .fontSize(16)
              .fontColor(Color.White)
          }
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .borderRadius(20)
          .margin({ top: 40 })

          Blank()

          Button('退出识别')
            .width('80%')
            .height(70)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .backgroundColor('rgba(53, 109, 115, 0.85)')
            .borderRadius(35)
            .onClick(() => {
              this.pageStack.replacePath({ name: 'Settings' });
            })
            .margin({ bottom: 50 })
        }
        .width('100%')
        .height('100%')
        .padding({ left: 20, right: 20 })
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

  @Builder
  buildWelcomePage() {
    NavDestination() {
      Column() {
        Column() {
          Text('探步').fontSize(36).fontWeight(FontWeight.Bold).fontColor('#1F2933')
          Text('智能视觉辅助').fontSize(18).fontColor('#667085').margin({ top: 8 })
        }

        Blank()

        BreathingCircle()

        Column() {
          Text('轻触屏幕任意位置').fontSize(27).fontWeight(FontWeight.Medium).fontColor('#1F2933')
          Text('开始识别').fontSize(24).fontColor('#356D73').fontWeight(FontWeight.Bold).margin({ top: 8 })
        }
        .opacity(this.promptOpacity)
        .translate({ y: this.promptOffset })
        .margin({ top: 24 })

        Text('环境感知 · 语音辅助').fontSize(16).fontColor('#667085').opacity(this.promptOpacity).margin({ top: 28 })
        Blank()
        Text('轻触任意位置进入识别模式')
          .fontSize(15)
          .fontColor('#98A2B3')
          .opacity(this.promptOpacity)
          .margin({ bottom: 30 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F4F7F6')
      .padding({
        left: 28,
        right: 28,
        top: 36,
        bottom: 24
      })
      .justifyContent(FlexAlign.Center)
      .onClick(() => {
        this.pageStack.pushPath({ name: 'CameraPage' })
      })
      .accessibilityText('轻触屏幕任意位置，开始识别')
    }
    .hideTitleBar(true)
  }

  @Builder
  buildSettingsPage() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Column() {
              Text('探步').fontSize(34).fontWeight(FontWeight.Bold).fontColor('#1F2933')
              Text('设置与帮助').fontSize(17).fontColor('#667085').margin({ top: 6 })
            }
            Blank()
          }
          .width('100%').margin({ top: 38 })

          Column() {
            Text('开始使用').fontSize(16).fontColor('#667085')
            Button('开始识别')
              .width('100%').height(78).fontSize(27).fontWeight(FontWeight.Bold)
              .fontColor(Color.White).backgroundColor('#356D73').borderRadius(24)
              .margin({ top: 14 })
              .onClick(() => { this.enterRecognition() })
              .accessibilityText('开始识别')
          }
          .width('100%').padding(22)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(26).margin({ top: 34 })

          Column() {
            Row() {
              Text('使用说明').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2933')
              Blank()
              Text('›').fontSize(30).fontColor('#667085')
            }.width('100%')
            Text('了解如何开始识别、退出识别以及使用语音辅助').fontSize(15).fontColor('#667085').margin({ top: 10 })
          }
          .width('100%').padding(22)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(24).margin({ top: 18 })
          .onClick(() => { this.openHelp() })

          Column() {
            Row() {
              Text('语音设置').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2933')
              Blank()
              Text('›').fontSize(30).fontColor('#667085')
            }.width('100%')
            Text(`当前语速：${this.speechSpeed}`).fontSize(15).fontColor('#667085').margin({ top: 10 })
          }
          .width('100%').padding(22)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(24).margin({ top: 18 })
          .onClick(() => { this.openVoiceSettings() })

          Column() {
            Text('无障碍设计').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2933')
            Text('大触控区域 · 语音反馈 · 振动提示').fontSize(15).fontColor('#667085').margin({ top: 10 })
            Row() {
              Text(this.vibrationEnabled ? '振动提示：开启' : '振动提示：关闭').fontSize(16).fontColor('#356D73')
              Blank()
              Text('点击设置').fontSize(15).fontColor('#98A2B3')
            }.width('100%').margin({ top: 18 })
          }
          .width('100%').padding(22).backgroundColor('#E8F1EF').borderRadius(24).margin({ top: 18 })

          Column() {
            Text('探步').fontSize(22).fontWeight(FontWeight.Bold).fontColor('#356D73')
            Text('看见环境，听见世界').fontSize(14).fontColor('#98A2B3').margin({ top: 6 })
          }.margin({ top: 34, bottom: 36 })
        }
        .width('100%').padding({ left: 24, right: 24 })
      }
      .width('100%').height('100%').backgroundColor('#F4F7F6')
    }
    .hideTitleBar(true)
  }

  @Builder
  buildHelpPage() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Text('‹').fontSize(42).fontColor('#356D73')
              .onClick(() => { this.backToSettings() })
            Text('使用说明').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#1F2933').margin({ left: 10 })
            Blank()
          }.width('100%').margin({ top: 32 })

          Text('简单三步开始使用').fontSize(18).fontColor('#667085').width('100%').margin({ top: 10, bottom: 24 })

          this.buildHelpCard('01', '打开应用', '启动声视后，应用会进入待机模式。')
          this.buildHelpCard('02', '轻触任意位置', '屏幕任意位置都可以触碰，不需要寻找按钮。')
          this.buildHelpCard('03', '听取语音提示', '应用会识别环境并通过语音告诉你周围的目标。')

          Column() {
            Text('退出识别').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2933')
            Text('在识别页面点击“退出识别”，返回设置与帮助页面。').fontSize(16).fontColor('#667085').margin({ top: 8 })
          }
          .width('100%').padding(22)
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(24).margin({ top: 16, bottom: 36 })
        }
        .width('100%').padding({ left: 24, right: 24 })
      }
      .width('100%').height('100%').backgroundColor('#F4F7F6')
    }
    .hideTitleBar(true)
  }

  @Builder
  buildHelpCard(number: string, title: string, description: string) {
    Row() {
      Stack() {
        if (deviceInfo.apiAvailable('26.0.0')) {
          Circle().width(52).height(52).fill('#E8F1EF')
        } else {
          Circle().width(52).height(52).backgroundColor('#E8F1EF')
        }
        Text(number).fontSize(17).fontWeight(FontWeight.Bold).fontColor('#356D73')
      }.width(56).height(56)

      Column() {
        Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor('#1F2933')
        Text(description).fontSize(15).fontColor('#667085').margin({ top: 7 })
      }.alignItems(HorizontalAlign.Start).margin({ left: 16 }).layoutWeight(1)
    }
    .width('100%').padding(20)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(24).margin({ bottom: 14 })
  }

  @Builder
  buildVoiceSettingsPage() {
    NavDestination() {
      Column() {
        Row() {
          Text('‹').fontSize(42).fontColor('#356D73')
            .onClick(() => { this.backToSettings() })
          Text('语音设置').fontSize(28).fontWeight(FontWeight.Bold).fontColor('#1F2933').margin({ left: 10 })
          Blank()
        }.width('100%').margin({ top: 32 })

        Column() {
          Text('播报速度').fontSize(21).fontWeight(FontWeight.Bold).fontColor('#1F2933')
          Text(`当前：${this.speechSpeed}`).fontSize(16).fontColor('#667085').margin({ top: 8 })
          Row() {
            this.buildSpeedButton('慢')
            this.buildSpeedButton('标准')
            this.buildSpeedButton('快')
          }.width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 20 })
        }
        .width('100%').padding(22)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(26).margin({ top: 34 })

        Column() {
          Row() {
            Column() {
              Text('振动提示').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2933')
              Text(this.vibrationEnabled ? '进入和退出识别时提供振动反馈' : '振动反馈已关闭')
                .fontSize(15).fontColor('#667085').margin({ top: 8 })
            }
            Blank()
            Button(this.vibrationEnabled ? '开启' : '关闭')
              .fontSize(15)
              .fontColor(this.vibrationEnabled ? Color.White : '#356D73')
              .backgroundColor(this.vibrationEnabled ? '#356D73' : '#E8F1EF')
              .borderRadius(18)
              .onClick(() => { this.vibrationEnabled = !this.vibrationEnabled })
          }.width('100%')
        }
        .width('100%').padding(22)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(26).margin({ top: 18 })

        Column() {
          Row() {
            Column() {
              Text('语音提示').fontSize(20).fontWeight(FontWeight.Bold).fontColor('#1F2933')
              Text(this.voiceHintEnabled ? '进入和退出识别时播放语音提示' : '语音提示已关闭')
                .fontSize(15).fontColor('#667085').margin({ top: 8 })
            }
            Blank()
            Button(this.voiceHintEnabled ? '开启' : '关闭')
              .fontSize(15)
              .fontColor(this.voiceHintEnabled ? Color.White : '#356D73')
              .backgroundColor(this.voiceHintEnabled ? '#356D73' : '#E8F1EF')
              .borderRadius(18)
              .onClick(() => { this.voiceHintEnabled = !this.voiceHintEnabled })
          }.width('100%')
        }
        .width('100%').padding(22)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(26).margin({ top: 18 })

        Blank()
        Text('这些设置将在后续 TTS 集成后生效').fontSize(14).fontColor('#98A2B3').margin({ bottom: 30 })
      }
      .width('100%').height('100%').padding({ left: 24, right: 24 })
      .backgroundColor('#F4F7F6')
    }
    .hideTitleBar(true)
  }

  @Builder
  buildSpeedButton(speed: string) {
    Button(speed)
      .width(92).height(52).fontSize(17).fontWeight(FontWeight.Bold)
      .fontColor(this.speechSpeed === speed ? Color.White : '#356D73')
      .backgroundColor(this.speechSpeed === speed ? '#356D73' : '#E8F1EF')
      .borderRadius(18)
      .onClick(() => { this.speechSpeed = speed })
  }
}