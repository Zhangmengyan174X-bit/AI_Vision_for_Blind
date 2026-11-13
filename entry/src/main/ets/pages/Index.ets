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
import { GyroManager } from '../utils/GyroManager';
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

  private isAppInBackground: boolean = false;
  private isRecognitionPageActive: boolean = false;
  private bgCallback: (() => void) | null = null;
  private fgCallback: (() => void) | null = null;
  private dangerHistory: Map<string, number> = new Map();
  private isModelReady: boolean = false;
  private speechTimer: number = -1;
  private isCameraInitializing: boolean = false;
  private receiverOutput: camera.PreviewOutput | null = null;
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

  @State isPreviewing: boolean = false;
  private isPhoneStable: boolean = true;

  private speakQueue: DetectedObject[] = [];
  private isSpeaking: boolean = false;
  private spokenHistory: Map<string, number> = new Map();
  private lastObjectState: Map<string, Map<string, number>> = new Map();

  private privacyContext: common.UIAbilityContext | null = null
  private privacyController: CustomDialogController | null = null

  private getObjectPriority(obj: DetectedObject): number {
    const vehicleLabels = [
      '汽车', '摩托车', '自行车', '公交车', '卡车', '出租车', '厢式货车', '救护车', '车辆', '陆地交通工具'
    ];
    const humanLabels = ['人', '男人', '女人', '男孩', '女孩'];

    if (vehicleLabels.includes(obj.label)) return 3;
    if (humanLabels.includes(obj.label)) return 2;

    const centerX = obj.box.left + obj.box.width / 2;
    if (centerX >= 0.3 && centerX <= 0.7) return 1;
    return 0;
  }

  private getObjectZone(obj: DetectedObject): string {
    const centerX = obj.box.left + obj.box.width / 2;
    if (centerX < 0.33) return 'L';
    if (centerX > 0.67) return 'R';
    return 'C';
  }

  onObjectDetected(objects: DetectedObject[]): void {
    if (objects.length === 0) return;
    const now = Date.now();

    const ignoreLabels = ['冰箱', '电视', '微波炉', '烤箱', '床', '马桶', '水槽'];
    const validObjects = objects.filter(obj => {
      const isIgnored = ignoreLabels.includes(obj.label);
      const isHeadphones = obj.labelId === 244;
      const isTooSmall = !isHeadphones && (obj.box.width * obj.box.height) < 0.03;
      const aspectRatio = obj.box.width / obj.box.height;
      const isWeirdShape = !isHeadphones && (aspectRatio > 3 || aspectRatio < 0.33);
      return !isIgnored && !isTooSmall && !isWeirdShape;
    });

    if (validObjects.length === 0) return;

    let hasDanger = false;
    let dangerSpeech = '';

    for (let i = 0; i < validObjects.length; i++) {
      const obj = validObjects[i];
      const currentArea = obj.box.width * obj.box.height;
      const centerX = obj.box.left + obj.box.width / 2;

      const posX = centerX < 0.33 ? 'L' : (centerX > 0.67 ? 'R' : 'C');
      const trackKey = `${obj.label}_${posX}`;

      const lastState = this.lastObjectState.get(trackKey);
      let growthRate = 0;
      let previousDangerCount = 0;

      if (lastState && this.isPhoneStable) {
        const timeDiff = now - (lastState.get('time') || 0);
        if (timeDiff > 0 && timeDiff < 1000) {
          const lastArea = lastState.get('area') || 0.01;
          growthRate = (Math.sqrt(currentArea) - Math.sqrt(lastArea)) / Math.sqrt(lastArea);
          previousDangerCount = lastState.get('dangerCount') || 0;
        }
      }

      const isAreaGrowingFast = (growthRate > 0.3 && currentArea > 0.08);
      let currentDangerCount = 0;

      if (isAreaGrowingFast) {
        currentDangerCount = previousDangerCount + 1;
        const lastDangerTime = this.dangerHistory.get(trackKey) || 0;
        const canWarn = now - lastDangerTime > 5000;

        if (currentDangerCount >= 2 && canWarn && !hasDanger) {
          let pos = centerX < 0.33 ? '左前方' : (centerX > 0.67 ? '右前方' : '正前方');
          dangerSpeech = `警告！${pos}有${obj.label}快速靠近，请注意安全`;
          this.dangerHistory.set(trackKey, now);
          hasDanger = true;
          currentDangerCount = 0;
        }
      }

      const stateMap = new Map<string, number>();
      stateMap.set('area', currentArea);
      stateMap.set('time', now);
      stateMap.set('dangerCount', currentDangerCount);
      this.lastObjectState.set(trackKey, stateMap);
    }

    if (hasDanger) {
      this.handleDanger(dangerSpeech);
      return;
    }

    for (let i = 0; i < validObjects.length; i++) {
      const obj = validObjects[i];
      const zone = this.getObjectZone(obj);
      const key = `${obj.labelId}_${zone}`;

      let inQueue = false;
      for (let j = 0; j < this.speakQueue.length; j++) {
        const qObj = this.speakQueue[j];
        if (qObj.labelId === obj.labelId && this.getObjectZone(qObj) === zone) {
          inQueue = true;
          break;
        }
      }

      const lastSpoken = this.spokenHistory.get(key) || 0;

      if (!inQueue && (now - lastSpoken > 8000)) {
        const pos = zone === 'L' ? '左前方' : (zone === 'R' ? '右前方' : '正前方');
        obj.speechText = `${pos}有${obj.label}`;
        obj.queuedAt = now;
        this.speakQueue.push(obj);
      }
    }

    this.speakQueue.sort((a, b) => {
      const diff = this.getObjectPriority(b) - this.getObjectPriority(a);
      if (diff !== 0) return diff;
      return b.score - a.score;
    });

    if (this.speakQueue.length > 3) {
      this.speakQueue = this.speakQueue.slice(0, 3);
    }

    this.processQueue();
  }

  private processQueue(): void {
    const now = Date.now();

    this.speakQueue = this.speakQueue.filter(obj => {
      return obj.queuedAt !== undefined && (now - obj.queuedAt < 2000);
    });

    if (this.isSpeaking || this.speakQueue.length === 0) return;

    this.isSpeaking = true;
    const obj = this.speakQueue.shift()!;

    const key = `${obj.labelId}_${this.getObjectZone(obj)}`;
    this.spokenHistory.set(key, Date.now());

    SpeechManager.getInstance().speak(obj.speechText!, this.getTtsSpeed());

    const baseMs = this.speechSpeed === '慢' ? 350 : (this.speechSpeed === '快' ? 220 : 280);
    const duration = obj.speechText!.length * baseMs + 800;

    this.clearSpeechTimer();
    this.speechTimer = setTimeout(() => {
      this.speechTimer = -1;
      this.isSpeaking = false;
      this.processQueue();
    }, duration);
  }

  private handleDanger(dangerSpeech: string): void {
    this.speakQueue = [];
    this.isSpeaking = false;
    this.clearSpeechTimer();

    SpeechManager.getInstance().stop();
    SpeechManager.getInstance().speak(dangerSpeech, 1.0);

    this.isSpeaking = true;
    this.speechTimer = setTimeout(() => {
      this.speechTimer = -1;
      this.isSpeaking = false;
      this.processQueue();
    }, 2500);
  }

  private async exitRecognition(): Promise<void> {
    this.isRecognitionPageActive = false;
    this.stopSpeechWork();
    this.lastObjectState.clear();
    this.dangerHistory.clear();
    await this.releaseCamera();
    this.pageStack.replacePath({ name: 'Settings' });
  }

  private clearSpeechTimer(): void {
    if (this.speechTimer !== -1) {
      clearTimeout(this.speechTimer);
      this.speechTimer = -1;
    }
  }

  aboutToAppear(): void {
    SpeechManager.getInstance().init();
    this.startWelcomeAnimation();
    this.inspectNNRT();

    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.checkPrivacy(context);

    this.bgCallback = () => {
      this.isAppInBackground = true;
      this.stopSpeechWork();
      this.stopGyroscopeSafely();
      this.releaseCamera();
      this.lastObjectState.clear();
      this.dangerHistory.clear();
    };

    this.fgCallback = () => {
      this.isAppInBackground = false;
      this.initGyroscope();
      if (this.isRecognitionPageActive && this.previewSurfaceId) {
        this.initCamera();
      }
    };

    this.getUIContext().getHostContext()?.eventHub.on('onBackground', this.bgCallback);
    this.getUIContext().getHostContext()?.eventHub.on('onForeground', this.fgCallback);

    this.yoloDetector = new YoloDetector(context);
    this.yoloDetector.loadModel().then((success: boolean) => {
      this.isModelReady = success;
      console.info(success ? 'YOLO 模型加载成功' : 'YOLO 模型加载失败');
    });
  }

  private checkPrivacy(context: common.UIAbilityContext): void {
    try {
      this.privacyContext = context
      const prefs = preferences.getPreferencesSync(context, { name: 'app_settings' })
      const agreed = prefs.getSync('privacyAgreed', false) as boolean
      if (agreed) {
        this.initGyroscope();
        return;
      }
      this.privacyController = new CustomDialogController({
        builder: PrivacyDialog({
          onAgree: () => { this.markPrivacyAgreed(); this.initGyroscope(); },
          onDisagree: () => { this.exitApp() }
        }),
        customStyle: true, alignment: DialogAlignment.Center, autoCancel: false
      })
      setTimeout(() => { this.privacyController?.open() }, 500)
    } catch (err) {}
  }

  private markPrivacyAgreed(): void {
    try {
      if (!this.privacyContext) return;
      const prefs = preferences.getPreferencesSync(this.privacyContext, { name: 'app_settings' })
      prefs.putSync('privacyAgreed', true)
      prefs.flush()
    } catch (err) {}
  }

  private exitApp(): void { try { this.privacyContext?.terminateSelf() } catch (err) {} }

  private startWelcomeAnimation(): void {
    this.promptOpacity = 0; this.promptOffset = 20;
    setTimeout(() => {
      this.getUIContext().animateTo({ duration: 1000, curve: Curve.EaseOut }, () => {
        this.promptOpacity = 1; this.promptOffset = 0;
      })
    }, 700)
  }

  private initGyroscope(): void {
    try {
      const gyro = GyroManager.getInstance();
      if (gyro.callback) return;

      gyro.callback = (data: sensor.GyroscopeResponse) => {
        const angularVelocity = Math.sqrt(data.x * data.x + data.y * data.y + data.z * data.z);
        this.isPhoneStable = angularVelocity <= 0.8;
      };
      sensor.on(sensor.SensorId.GYROSCOPE, gyro.callback, { interval: 100000000 });
    } catch (error) {}
  }

  private stopGyroscopeSafely(): void {
    try {
      const gyro = GyroManager.getInstance();
      if (gyro.callback) {
        sensor.off(sensor.SensorId.GYROSCOPE, gyro.callback);
        gyro.callback = null;
      }
    } catch (error) {}
  }

  private stopSpeechWork(): void {
    this.clearSpeechTimer();
    this.speakQueue = [];
    this.isSpeaking = false;
    SpeechManager.getInstance().stop();
  }

  private inspectNNRT(): void {
    try { mindSporeLite.getAllNNRTDeviceDescriptions(); } catch (e) {}
  }

  aboutToDisappear(): void {
    if (this.bgCallback) this.getUIContext().getHostContext()?.eventHub.off('onBackground', this.bgCallback);
    if (this.fgCallback) this.getUIContext().getHostContext()?.eventHub.off('onForeground', this.fgCallback);
    this.stopSpeechWork();
    SpeechManager.getInstance().shutdown();
    this.releaseCamera();
    if (this.yoloDetector) { this.yoloDetector.release(); this.yoloDetector = null; }
    this.stopGyroscopeSafely();
    this.lastObjectState.clear();
    this.spokenHistory.clear();
  }

  async initCamera(): Promise<void> {
    if (!this.isRecognitionPageActive || this.isAppInBackground || this.isPreviewing || this.isCameraInitializing) {
      return;
    }
    if (!this.previewSurfaceId) return;

    this.isCameraInitializing = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.cameraManager = camera.getCameraManager(context);
      const cameras = this.cameraManager.getSupportedCameras();
      const backCamera = cameras.find(cam => cam.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK) || cameras[0];
      if (!backCamera) return;

      this.cameraInput = this.cameraManager.createCameraInput(backCamera);
      await this.cameraInput.open();

      const outputCapability = this.cameraManager.getSupportedOutputCapability(backCamera, camera.SceneMode.NORMAL_PHOTO);
      let previewProfile = outputCapability.previewProfiles[0];
      for (let i = 1; i < outputCapability.previewProfiles.length; i++) {
        const p = outputCapability.previewProfiles[i];
        if (p.size.width * p.size.height > previewProfile.size.width * previewProfile.size.height) previewProfile = p;
      }

      this.previewOutput = this.cameraManager.createPreviewOutput(previewProfile, this.previewSurfaceId);
      const receiverSize: image.Size = { width: previewProfile.size.width, height: previewProfile.size.height };
      this.imageReceiver = image.createImageReceiver(receiverSize, image.ImageFormat.JPEG, 8);
      this.receiverSurfaceId = await this.imageReceiver.getReceivingSurfaceId();

      this.imageReceiver.on('imageArrival', () => {
        this.imageReceiver?.readNextImage((err: BusinessError, nextImage: image.Image) => {
          if (err || !nextImage) return;
          const now = Date.now();
          if (now - this.lastDetectTime < this.detectInterval || this.isDetecting) {
            nextImage.release(); return;
          }
          this.lastDetectTime = now;
          this.isDetecting = true;
          this.detectObject(nextImage).finally(() => { this.isDetecting = false; nextImage.release(); });
        });
      });

      this.receiverOutput = this.cameraManager.createPreviewOutput(previewProfile, this.receiverSurfaceId);
      this.captureSession = this.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.Session;
      this.captureSession.beginConfig();
      this.captureSession.addInput(this.cameraInput);
      this.captureSession.addOutput(this.previewOutput);
      this.captureSession.addOutput(this.receiverOutput);
      await this.captureSession.commitConfig();
      await this.captureSession.start();
      this.isPreviewing = true;
    } catch (err) {
      console.error(`[Camera] 初始化失败: ${JSON.stringify(err)}`);
      await this.releaseCamera();
    } finally {
      this.isCameraInitializing = false;
    }
  }

  async releaseCamera(): Promise<void> {
    if (this.imageReceiver) {
      try { this.imageReceiver.off('imageArrival'); await this.imageReceiver.release(); } catch (e) {}
      this.imageReceiver = null;
    }
    if (this.captureSession) {
      try { await this.captureSession.stop(); } catch (e) {}
      try { await this.captureSession.release(); } catch (e) {}
      this.captureSession = null;
    }
    if (this.receiverOutput) {
      try { await this.receiverOutput.release(); } catch (e) {}
      this.receiverOutput = null;
    }
    if (this.previewOutput) {
      try { await this.previewOutput.release(); } catch (e) {}
      this.previewOutput = null;
    }
    if (this.cameraInput) {
      try { await this.cameraInput.close(); } catch (e) {}
      this.cameraInput = null;
    }
    this.isPreviewing = false;
  }

  async detectObject(img: image.Image): Promise<void> {
    if (!this.isRecognitionPageActive || this.isAppInBackground || !this.isModelReady || this.yoloDetector === null) {
      return;
    }

    let imageSource: image.ImageSource | null = null;
    let pixelMap: image.PixelMap | null = null;

    try {
      const component = await img.getComponent(image.ComponentType.JPEG);
      if (!component || !component.byteBuffer) throw new Error('无法获取 JPEG 图像数据');

      imageSource = image.createImageSource(component.byteBuffer);
      if (!imageSource) throw new Error('ImageSource 创建失败');

      pixelMap = await imageSource.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: true
      });

      const info = pixelMap.getImageInfoSync();
      if (info.pixelFormat !== image.PixelMapFormat.RGBA_8888) throw new Error('PixelMap 不是 RGBA_8888');

      const inputData = await this.preprocessImage(pixelMap);
      if (inputData.length !== 3 * 640 * 640) throw new Error('模型输入长度错误');

      const objects: DetectedObject[] = await this.yoloDetector.detect(inputData);

      if (this.isRecognitionPageActive && !this.isAppInBackground && objects.length > 0) {
        this.onObjectDetected(objects);
      }

    } catch (err) {
      const e = err as BusinessError;
      console.error(`[YOLO] 图像处理失败: code=${e.code}, message=${e.message}`);
    } finally {
      if (pixelMap) { try { await pixelMap.release(); } catch (e) {} }
      if (imageSource) { try { await imageSource.release(); } catch (e) {} }
    }
  }

  private async preprocessImage(pixelMap: image.PixelMap): Promise<Float32Array> {
    const SIZE = 640;
    const info = pixelMap.getImageInfoSync();

    if (!info.size || info.size.width <= 0 || info.size.height <= 0) {
      throw new Error('无效图像尺寸');
    }
    if (info.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
      throw new Error('输入像素格式错误');
    }

    await pixelMap.scale(SIZE / info.size.width, SIZE / info.size.height);

    const scaledInfo = pixelMap.getImageInfoSync();
    if (scaledInfo.size.width !== SIZE || scaledInfo.size.height !== SIZE) {
      throw new Error('Resize 后尺寸不正确');
    }

    const planeSize = SIZE * SIZE;
    const byteLength = pixelMap.getPixelBytesNumber();
    if (byteLength !== planeSize * 4) {
      throw new Error(`RGBA 数据长度异常: ${byteLength}`);
    }

    const buffer = new ArrayBuffer(byteLength);
    await pixelMap.readPixelsToBuffer(buffer);
    const rgba = new Uint8Array(buffer);

    const result = new Float32Array(3 * planeSize);

    for (let i = 0; i < planeSize; i++) {
      result[i] = rgba[i * 4] / 255.0;
      result[planeSize + i] = rgba[i * 4 + 1] / 255.0;
      result[planeSize * 2 + i] = rgba[i * 4 + 2] / 255.0;
    }

    return result;
  }

  private getTtsSpeed(): number {
    if (this.speechSpeed === '慢') return 0.75;
    if (this.speechSpeed === '快') return 1.3;
    return 1.0;
  }

  private vibrate(duration: number): void {
    if (!this.vibrationEnabled) return;
    try { vibrator.startVibration({ type: 'time', duration: duration }, { usage: 'notification' }).catch(() => {}); } catch (err) {}
  }

  private enterRecognition(): void {
    this.vibrate(60);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    requestCameraPermission(context).then((granted) => {
      if (granted) this.pageStack.pushPath({ name: 'CameraPage' });
    });
  }

  private openHelp(): void { this.pageStack.pushPath({ name: 'Help' }) }
  private openVoiceSettings(): void { this.pageStack.pushPath({ name: 'VoiceSettings' }) }
  private backToSettings(): void { this.pageStack.pop() }

  private async speakHelpPage(): Promise<void> {
    if (!this.voiceHintEnabled) return;
    await SpeechManager.getInstance().init();
    SpeechManager.getInstance().speak('使用说明。简单三步开始使用。第一步，打开应用。第二步，轻触屏幕任意位置。第三步，听取语音提示。', this.getTtsSpeed());
  }

  // ==========================================
  // UI 代码原样保留
  // ==========================================
  @Builder
  buildCameraPage() {
    NavDestination() {
      Stack() {
        XComponent({ id: 'camera_preview', type: XComponentType.SURFACE, controller: this.xComponentController })
          .width('100%').height('100%').renderFit(RenderFit.RESIZE_COVER)
          .onLoad(() => {
            this.isRecognitionPageActive = true;
            this.previewSurfaceId = this.xComponentController.getXComponentSurfaceId();
            this.initCamera();
          })
          .accessibilityText('相机取景画面')
        Column() {
          Row() {
            Column().width(10).height(10).backgroundColor(AppColors.sageLight).borderRadius(5)
            Text('正在识别中').fontSize(15).fontColor(AppColors.white).margin({ left: 8 })
          }.backgroundColor(AppColors.overlay).padding({ left: 16, right: 18, top: 9, bottom: 9 }).borderRadius(20).margin({ top: 54 }).accessibilityGroup(true)
          Blank()
          Column() {
            Button('退出识别').width('100%').height(72).fontSize(24).fontWeight(FontWeight.Bold).fontColor(AppColors.white)
              .backgroundColor(AppColors.overlayDeep).borderRadius(36).border({ width: 1, color: 'rgba(255, 255, 255, 0.22)' })
              .shadow({ radius: 20, color: 'rgba(0, 0, 0, 0.28)', offsetX: 0, offsetY: 8 })
              .onClick(() => {
                this.vibrate(60);
                this.exitRecognition();
              })
              .accessibilityText('退出识别，返回设置页面')
          }.width('100%').padding({ left: 24, right: 24, top: 72, bottom: 34 })
          .linearGradient({ angle: 180, colors: [['rgba(48, 54, 58, 0)', 0.0], ['rgba(48, 54, 58, 0.55)', 1.0]] })
        }.width('100%').height('100%')
      }.width('100%').height('100%')
    }.hideTitleBar(true)
  }

  build() {
    Navigation(this.pageStack) {
      this.buildWelcomePage()
    }.navDestination(this.PageMap).mode(NavigationMode.Stack).hideTitleBar(true)
  }

  @Builder
  PageMap(name: string) {
    if (name === 'CameraPage') { this.buildCameraPage() }
    else if (name === 'Settings') { this.buildSettingsPage() }
    else if (name === 'Help') { this.buildHelpPage() }
    else if (name === 'VoiceSettings') { this.buildVoiceSettingsPage() }
  }

  @Builder
  buildWelcomePage() {
    NavDestination() {
      Stack() {
        Column().width(280).height(280).backgroundColor(AppColors.sage).borderRadius(140).opacity(0.07).position({ x: '-25%', y: '-8%' })
        Column().width(220).height(220).backgroundColor(AppColors.sageDeep).borderRadius(110).opacity(0.06).position({ x: '72%', y: '76%' })

        Column() {
          Column() {
            Text('探步').fontSize(40).fontWeight(FontWeight.Bold).fontColor(AppColors.ink).letterSpacing(4)
            Text('智能视觉辅助').fontSize(16).fontColor(AppColors.ink).letterSpacing(6).margin({ top: 10 })
          }.margin({ top: 52 })
          Blank()
          BreathingCircle()
          Blank()
          Column() {
            Text('轻触屏幕任意位置').fontSize(24).fontWeight(FontWeight.Medium).fontColor(AppColors.ink)
            Text('开始识别').fontSize(28).fontColor(AppColors.sage).fontWeight(FontWeight.Bold).margin({ top: 10 })
          }.opacity(this.promptOpacity).translate({ y: this.promptOffset })

          Row() {
            Column().width(8).height(8).backgroundColor(AppColors.sage).borderRadius(4)
            Text('环境感知 · 语音辅助').fontSize(14).fontColor(AppColors.ink).margin({ left: 8 })
          }.padding({ left: 18, right: 18, top: 10, bottom: 10 }).backgroundColor('rgba(246, 247, 244, 0.65)').borderRadius(22).opacity(this.promptOpacity).margin({ top: 30, bottom: 44 })
        }
        .width('100%').height('100%').padding({ left: 28, right: 28 })
        .onClick(() => { this.enterRecognition() })
        .accessibilityText('轻触屏幕任意位置，开始识别')
      }.width('100%').height('100%').linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }.hideTitleBar(true)
  }

  @Builder
  buildSettingsPage() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Column() {
              Text('探步').fontSize(34).fontWeight(FontWeight.Bold).fontColor(AppColors.ink).letterSpacing(2)
              Text('设置与帮助').fontSize(16).fontColor(AppColors.ink).margin({ top: 6 })
            }.alignItems(HorizontalAlign.Start)
            Blank()
          }.width('100%').margin({ top: 44 })

          Column() {
            Row() {
              Text('开始使用').fontSize(13).fontColor(AppColors.ink).letterSpacing(3)
              Blank()
            }.width('100%')
            Button('开始识别')
              .width('100%').height(76).fontSize(26).fontWeight(FontWeight.Bold).fontColor(AppColors.white)
              .backgroundColor(AppColors.sage).borderRadius(22).shadow(AppColors.shadowButton).margin({ top: 16 })
              .onClick(() => { this.enterRecognition() }).accessibilityText('开始识别')
          }.width('100%').padding(22).backgroundColor(AppColors.card).borderRadius(24).shadow(AppColors.shadowCard).margin({ top: 32 })

          this.buildEntryCard('说', '使用说明', '了解如何开始识别、退出识别以及使用语音辅助', () => { this.openHelp() })
          this.buildEntryCard('语', '语音设置', `当前语速：${this.speechSpeed}`, () => { this.openVoiceSettings() })

          Column() {
            Row() {
              Text('无障碍设计').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
              Blank()
              Text('已启用').fontSize(13).fontColor(AppColors.sageDeep).padding({ left: 12, right: 12, top: 5, bottom: 5 }).backgroundColor('rgba(99, 145, 138, 0.14)').borderRadius(12)
            }.width('100%')
            Text('大触控区域 · 语音反馈 · 振动提示').fontSize(15).fontColor(AppColors.ink).margin({ top: 10 })
            Divider().strokeWidth(0.5).color(AppColors.line).margin({ top: 16, bottom: 14 })
            Row() {
              Text(this.vibrationEnabled ? '振动提示：开启' : '振动提示：关闭').fontSize(15).fontColor(AppColors.sageDeep)
              Blank()
              Text('点击设置').fontSize(14).fontColor(AppColors.mist)
            }.width('100%').onClick(() => { this.openVoiceSettings() })
          }.width('100%').padding(22).backgroundColor(AppColors.sageSoft).borderRadius(24).margin({ top: 18 }).accessibilityGroup(true)

          Column() {
            Text('探步').fontSize(22).fontWeight(FontWeight.Bold).fontColor(AppColors.sage).letterSpacing(2)
            Text('看见环境，听见世界').fontSize(14).fontColor(AppColors.mist).margin({ top: 6 })
          }.margin({ top: 36, bottom: 40 })
        }.width('100%').padding({ left: 24, right: 24 })
      }.width('100%').height('100%').linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }.hideTitleBar(true)
  }

  @Builder
  buildHelpPage() {
    NavDestination() {
      Scroll() {
        Column() {
          Row() {
            Stack() {
              Column().width(44).height(44).backgroundColor(AppColors.card).borderRadius(22)
              Text('‹').fontSize(26).fontColor(AppColors.ink).margin({ bottom: 4 })
            }.shadow(AppColors.shadowCard).onClick(() => { this.backToSettings() }).accessibilityText('返回上一页')
            Text('使用说明').fontSize(26).fontWeight(FontWeight.Bold).fontColor(AppColors.ink).margin({ left: 14 })
            Blank()
          }.width('100%').margin({ top: 40 })

          Text('简单三步开始使用').fontSize(16).fontColor(AppColors.ink).width('100%').margin({ top: 12, bottom: 24 })
          this.buildHelpCard('01', '打开应用', '启动探步后，应用进入待机模式。')
          this.buildHelpCard('02', '轻触屏幕任意位置', '即可进入识别模式。')
          this.buildHelpCard('03', '听取语音提示', '应用会识别环境并通过语音告诉你周围的目标。')

          Column() {
            Row() {
              Stack() {
                Column().width(48).height(48).backgroundColor(AppColors.sageSoft).borderRadius(24)
                Text('退').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.sageDeep)
              }
              Column() {
                Text('退出识别').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
                Text('在识别页面点击“退出识别”，返回设置与帮助页面。').fontSize(15).fontColor(AppColors.ink).margin({ top: 7 })
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 16 })
            }.width('100%')
          }.width('100%').padding(20).backgroundColor(AppColors.card).borderRadius(24).shadow(AppColors.shadowCard).margin({ top: 4, bottom: 40 }).accessibilityGroup(true)
        }.width('100%').padding({ left: 24, right: 24 })
      }.width('100%').height('100%').linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }.hideTitleBar(true).onShown(() => { this.speakHelpPage() }).onHidden(() => { SpeechManager.getInstance().stop() })
  }

  @Builder
  buildEntryCard(mark: string, title: string, subtitle: string, onTap: () => void) {
    Row() {
      Stack() {
        Column().width(48).height(48).backgroundColor(AppColors.sageSoft).borderRadius(24)
        Text(mark).fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.sageDeep)
      }
      Column() {
        Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
        Text(subtitle).fontSize(14).fontColor(AppColors.ink).margin({ top: 6 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1).margin({ left: 16 })
      Text('›').fontSize(28).fontColor(AppColors.mist)
    }.width('100%').padding(20).backgroundColor(AppColors.card).borderRadius(24).shadow(AppColors.shadowCard).margin({ top: 18 }).onClick(onTap).accessibilityGroup(true).accessibilityText(title + '，' + subtitle)
  }

  @Builder
  buildHelpCard(number: string, title: string, description: string) {
    Row() {
      Stack() {
        Column().width(52).height(52).backgroundColor(AppColors.sageSoft).borderRadius(26)
        Text(number).fontSize(17).fontWeight(FontWeight.Bold).fontColor(AppColors.sageDeep)
      }.width(56).height(56)
      Column() {
        Text(title).fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
        Text(description).fontSize(15).fontColor(AppColors.ink).margin({ top: 7 })
      }.alignItems(HorizontalAlign.Start).margin({ left: 16 }).layoutWeight(1)
    }.width('100%').padding(20).backgroundColor(AppColors.card).borderRadius(24).shadow(AppColors.shadowCard).margin({ bottom: 14 }).accessibilityGroup(true)
  }

  @Builder
  buildVoiceSettingsPage() {
    NavDestination() {
      Column() {
        Row() {
          Stack() {
            Column().width(44).height(44).backgroundColor(AppColors.card).borderRadius(22)
            Text('‹').fontSize(26).fontColor(AppColors.ink).margin({ bottom: 4 })
          }.shadow(AppColors.shadowCard).onClick(() => { this.backToSettings() }).accessibilityText('返回上一页')
          Text('语音设置').fontSize(26).fontWeight(FontWeight.Bold).fontColor(AppColors.ink).margin({ left: 14 })
          Blank()
        }.width('100%').margin({ top: 40 })

        Column() {
          Row() {
            Text('播报速度').fontSize(20).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
            Blank()
            Text(`当前：${this.speechSpeed}`).fontSize(14).fontColor(AppColors.sageDeep)
          }.width('100%')
          Row() {
            this.buildSpeedButton('慢')
            this.buildSpeedButton('标准')
            this.buildSpeedButton('快')
          }.width('100%').padding(4).backgroundColor(AppColors.sageSoft).borderRadius(20).margin({ top: 18 })
        }.width('100%').padding(22).backgroundColor(AppColors.card).borderRadius(24).shadow(AppColors.shadowCard).margin({ top: 30 })

        Column() {
          Row() {
            Column() {
              Text('振动提示').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
              Text(this.vibrationEnabled ? '进入和退出识别时提供振动反馈' : '振动反馈已关闭').fontSize(14).fontColor(AppColors.ink).margin({ top: 7 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.vibrationEnabled })
              .selectedColor(AppColors.sage).switchPointColor(AppColors.white).accessibilityText('振动提示开关')
              .onChange((isOn: boolean) => { this.vibrationEnabled = isOn; if (isOn) this.vibrate(60) })
          }.width('100%')
          Divider().strokeWidth(0.5).color(AppColors.line).margin({ top: 18, bottom: 18 })
          Row() {
            Column() {
              Text('语音提示').fontSize(19).fontWeight(FontWeight.Bold).fontColor(AppColors.ink)
              Text(this.voiceHintEnabled ? '进入和退出识别时播放语音提示' : '语音提示已关闭').fontSize(14).fontColor(AppColors.ink).margin({ top: 7 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.voiceHintEnabled })
              .selectedColor(AppColors.sage).switchPointColor(AppColors.white).accessibilityText('语音提示开关')
              .onChange((isOn: boolean) => { this.voiceHintEnabled = isOn })
          }.width('100%')
        }.width('100%').padding(22).backgroundColor(AppColors.card).borderRadius(24).shadow(AppColors.shadowCard).margin({ top: 18 })
        Blank()
      }.width('100%').height('100%').padding({ left: 24, right: 24 }).linearGradient({ angle: 160, colors: PAGE_GRADIENT })
    }.hideTitleBar(true)
  }

  @Builder
  buildSpeedButton(speed: string) {
    Button(speed)
      .layoutWeight(1).height(52).fontSize(17).fontWeight(FontWeight.Bold)
      .fontColor(this.speechSpeed === speed ? AppColors.white : AppColors.sageDeep)
      .backgroundColor(this.speechSpeed === speed ? AppColors.sage : Color.Transparent)
      .borderRadius(16)
      .shadow(this.speechSpeed === speed ? { radius: 10, color: 'rgba(99, 145, 138, 0.35)', offsetX: 0, offsetY: 4 } : { radius: 0, color: Color.Transparent })
      .onClick(() => { this.speechSpeed = speed })
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

      Text('探步为纯离线应用：所有图像识别与语音处理均在本机完成，不收集、不上传、不共享任何个人信息。相机画面仅用于实时识别，不会保存。应用使用陀螺仪传感器判断设备平稳状态，以减少误报。')
        .fontSize(15)
        .fontColor(AppColors.ink)
        .lineHeight(24)
        .margin({ top: 14 })

      Text('查看完整《隐私政策》')
        .fontSize(15)
        .fontColor(AppColors.sageDeep)
        .margin({ top: 12 })
        .accessibilityText('查看完整隐私政策链接')
        .onClick(() => {
          const privacyUrl: string = 'https://github.com/Zhangmengyan174X-bit/tanbu-privacy/blob/main/privacy.md'
          try {
            const ctx = getContext(this) as common.UIAbilityContext
            ctx.openLink(privacyUrl)
          } catch (err) { console.error('[隐私政策] 调用异常'); }
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
}