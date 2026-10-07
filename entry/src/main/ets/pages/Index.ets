import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { requestCameraPermission } from '../entryability/PermissionHelper';
import { objectDetection, visionBase } from '@kit.CoreVisionKit';
import { SpeechManager } from '../utils/SpeechManager';
import { RecognitionPage } from '../ui/pages/RecognitionPage';
import { SettingsPage } from '../ui/pages/SettingsPage';

// 标签数字 → 中文
const LABEL_MAP: Record<number, string> = {
  0: '风景', 1: '动物', 2: '植物', 3: '建筑',
  5: '人脸', 6: '表格', 7: '文本', 8: '人头',
  9: '猫头', 10: '狗头', 11: '食物', 12: '汽车',
  13: '人体', 21: '文档', 22: '卡证'
};
@Entry
@Component
struct Index {
  @Provide('pageStack') pageStack: NavPathStack = new NavPathStack()
  private xComponentController: XComponentController = new XComponentController();
  private cameraManager: camera.CameraManager | null = null;
  private cameraInput: camera.CameraInput | null = null;
  private previewOutput: camera.PreviewOutput | null = null;
  private captureSession: camera.Session | null = null;
  private previewSurfaceId: string = '';
  private imageReceiver: image.ImageReceiver | null = null;
  private receiverSurfaceId: string = '';
  private lastDetectTime: number = 0;
  private lastSpokenLabel: string = '';
  private detectInterval: number = 1000;
  @State isPreviewing: boolean = false;

  onObjectDetected(label: string): void {
    if (label === this.lastSpokenLabel) {
      return;
    }
    this.lastSpokenLabel = label;

    // 调用 TTS 播报
    SpeechManager.getInstance().speak(`前方有${label}`);
  }

  aboutToAppear(): void {
    SpeechManager.getInstance().init();

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    requestCameraPermission(context).then((granted) => {
      if (!granted) {
        console.error('权限未授予');
      }
    });
  }

  aboutToDisappear(): void {
    SpeechManager.getInstance().shutdown();
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

      // 获取预览流配置
      const outputCapability = this.cameraManager.getSupportedOutputCapability(
        backCamera, camera.SceneMode.NORMAL_PHOTO
      );
      const previewProfile = outputCapability.previewProfiles[0];

      // 第一路：给 XComponent 显示
      this.previewOutput = this.cameraManager.createPreviewOutput(
        previewProfile, this.previewSurfaceId
      );

      // ========== 第二路：给 ImageReceiver 抽帧（双路预览）==========
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

          // 【节流】距上次识别不足 detectInterval 毫秒，跳过本帧
          const now = Date.now();
          if (now - this.lastDetectTime < this.detectInterval) {
            nextImage.release();
            return;
          }
          this.lastDetectTime = now;

          this.detectObject(nextImage);
          nextImage.release();
        });
      });

      // 关键：用同一个 previewProfile 创建第二路输出
      const receiverOutput = this.cameraManager.createPreviewOutput(
        previewProfile, this.receiverSurfaceId
      );

      // 把两路输出都加入到 Session
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
    try {
      const component = await img.getComponent(image.ComponentType.JPEG);
      if (!component || !component.byteBuffer) {
        console.error('获取图像数据失败');
        return;
      }

      // 读取真实的图像尺寸（只声明一次）
      const realWidth = img.size.width;
      const realHeight = img.size.height;

      // 创建空的 PixelMap
      const pixelMap = image.createPixelMapSync({
        size: { width: realWidth, height: realHeight },
        srcPixelFormat: image.PixelMapFormat.NV21,
        editable: true
      });

      // 裁剪掉多余的填充
      pixelMap.cropSync({
        x: 0,
        y: 0,
        size: {
          width: realWidth,
          height: realHeight
        }
      });

      const imageData: visionBase.ImageData = { pixelMap: pixelMap };
      const request: visionBase.Request = { inputData: imageData };

      const detector = await objectDetection.ObjectDetector.create();
      if (!detector) {
        console.error('ObjectDetector 创建失败');
        pixelMap.release();
        return;
      }

      const response = await detector.process(request);

      if (response && response.objects && response.objects.length > 0) {
        console.info(`识别到 ${response.objects.length} 个目标:`);
        response.objects.forEach((obj: objectDetection.VisionObject, index: number) => {
          const labelNames = obj.labels.map((l: number) => LABEL_MAP[l] || `未知(${l})`);
          console.info(
            `  [${index}] 标签: ${labelNames.join(', ')}, ` +
              `置信度: ${obj.score.toFixed(3)}`
          );
        });

        // 取置信度最高的目标，传给队友一的接口
        const topObj = response.objects[0];
        const topLabel = LABEL_MAP[topObj.labels[0]] || `未知(${topObj.labels[0]})`;
        this.onObjectDetected(topLabel);
      } else {
        console.info('未识别到目标');
      }

      await detector.destroy();
      pixelMap.release();
    } catch (err) {
      const e = err as BusinessError;
      console.error(`识别失败: code=${e.code}, message=${e.message}`);
    }
  }

  @Builder
  buildCameraPage() {
    NavDestination() {
      Column() {
        XComponent({
          id: 'camera_preview',
          type: XComponentType.SURFACE,
          controller: this.xComponentController
        })
          .width('100%')
          .height('60%')
          .onLoad(() => {
            this.previewSurfaceId = this.xComponentController.getXComponentSurfaceId();
            console.info('SurfaceId 就绪: ' + this.previewSurfaceId);
          })

        Row() {
          Button('打开相机')
            .onClick(() => this.initCamera())
            .enabled(!this.isPreviewing)

          Button('关闭相机')
            .onClick(() => this.releaseCamera())
            .enabled(this.isPreviewing)
        }
        .margin(20)
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
  buildWelcomePage() {
    NavDestination() {
      Column() {
        Text('声视')
          .fontSize(36)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1F2933')

        Text('智能视觉辅助')
          .fontSize(18)
          .fontColor('#667085')
          .margin({ top: 8 })

        Blank()

        Button('开始识别')
          .width('80%')
          .height(70)
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor('#356D73')
          .borderRadius(24)
          .onClick(() => {
            this.pageStack.pushPath({ name: 'CameraPage' })
          })

        Blank()

        Button('设置')
          .width('80%')
          .height(60)
          .fontSize(20)
          .fontColor('#356D73')
          .backgroundColor('#E8F1EF')
          .borderRadius(24)
          .margin({ top: 16 })
          .onClick(() => {
            this.pageStack.pushPath({ name: 'SettingsPage' })
          })
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F4F7F6')
      .padding({ left: 28, right: 28 })
      .justifyContent(FlexAlign.Center)
    }
    .hideTitleBar(true)
  }

  @Builder
  PageMap(name: string) {
    if (name === 'CameraPage') {
      this.buildCameraPage()
    } else if (name === 'RecognitionPage') {
      RecognitionPage()
    } else if (name === 'SettingsPage') {
      SettingsPage()
    }
  }
}