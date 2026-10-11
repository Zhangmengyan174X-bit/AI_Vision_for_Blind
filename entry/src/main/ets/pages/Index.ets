import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { requestCameraPermission } from '../entryability/PermissionHelper';
import { SpeechManager } from '../utils/SpeechManager';
import { RecognitionPage } from '../ui/pages/RecognitionPage';
import { SettingsPage } from '../ui/pages/SettingsPage';
import { YoloDetector, DetectedObject } from '../utils/YoloDetector';

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
  private isDetecting: boolean = false;

  // YOLO 检测器
  private yoloDetector: YoloDetector | null = null;

  @State isPreviewing: boolean = false;

  // 张雅萱后续在这里做优先级判定 + 去重 + TTS
  onObjectDetected(objects: DetectedObject[]): void {
    if (objects.length === 0) {
      return;
    }

    // 暂时取置信度最高的播报（YoloDetector 已经按 score 降序排好）
    const best = objects[0];

    // 简易去重：同一标签不重复播报
    if (best.label === this.lastSpokenLabel) {
      return;
    }
    this.lastSpokenLabel = best.label;

    SpeechManager.getInstance().speak(`前方有${best.label}`);
  }

  aboutToAppear(): void {
    SpeechManager.getInstance().init();

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;

    // 加载 YOLO 模型
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

  aboutToDisappear(): void {
    SpeechManager.getInstance().shutdown();
    if (this.yoloDetector) {
      this.yoloDetector.release();
      this.yoloDetector = null;
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
      const previewProfile = outputCapability.previewProfiles[0];

      // 第一路：给 XComponent 显示
      this.previewOutput = this.cameraManager.createPreviewOutput(
        previewProfile, this.previewSurfaceId
      );

      // ========== 第二路：给 ImageReceiver 抽帧 ==========
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
      // 1. 拿原始字节
      const component = await img.getComponent(image.ComponentType.JPEG);
      if (!component || !component.byteBuffer) {
        console.error('获取图像数据失败');
        return;
      }

      // 2. 真实宽高
      const realWidth = img.size.width;
      const realHeight = img.size.height;

      // 3. 解码成 PixelMap
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

      // 4. 预处理成 YOLO 需要的 Float32Array
      const inputData: Float32Array = await this.preprocessImage(pixelMap);

      // 5. YOLO 推理
      const objects: DetectedObject[] = await this.yoloDetector.detect(inputData);

      if (objects.length > 0) {
        console.info(`YOLO 识别到 ${objects.length} 个目标`);
        objects.forEach((obj: DetectedObject, index: number) => {
          console.info(`  [${index}] ${obj.label} score=${obj.score.toFixed(3)}`);
        });
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

  /**
   * 把 PixelMap 预处理成 YOLO 需要的输入：
   * 1×3×640×640 的 Float32Array，归一化到 0~1，CHW 顺序
   */
  private async preprocessImage(pixelMap: image.PixelMap): Promise<Float32Array> {
    const INPUT_SIZE = 640;
    try {
      // 1. 缩放到 640x640
      const info = pixelMap.getImageInfoSync();
      const scaleX = INPUT_SIZE / info.size.width;
      const scaleY = INPUT_SIZE / info.size.height;
      await pixelMap.scale(scaleX, scaleY);

      // 2. 读 RGBA 像素
      const buffer = new ArrayBuffer(INPUT_SIZE * INPUT_SIZE * 4);
      await pixelMap.readPixelsToBuffer(buffer);
      const rgba = new Uint8Array(buffer);

      // 3. 转 CHW Float32，归一化到 0~1
      const float32 = new Float32Array(1 * 3 * INPUT_SIZE * INPUT_SIZE);
      const channelSize = INPUT_SIZE * INPUT_SIZE;
      for (let i = 0; i < channelSize; i++) {
        float32[i] = rgba[i * 4] / 255.0;
        float32[channelSize + i] = rgba[i * 4 + 1] / 255.0;
        float32[channelSize * 2 + i] = rgba[i * 4 + 2] / 255.0;
      }
      return float32;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`预处理失败: code=${e.code}, message=${e.message}`);
      return new Float32Array(1 * 3 * INPUT_SIZE * INPUT_SIZE);
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