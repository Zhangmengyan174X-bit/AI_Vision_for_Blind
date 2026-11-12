// utils/YoloDetector.ets
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const NUM_BOXES = 8400;

const IGNORED_KEYWORDS: string[] = [
  '烤面包机', '吹风机', '牙刷', '花瓶', '剪刀', '泰迪熊', '时钟', '盆栽'
];

// 严格 80 类 COCO
const COCO_LABELS: string[] = [
  '人', '自行车', '汽车', '摩托车', '飞机', '公交车', '火车', '卡车', '船',
  '红绿灯', '消防栓', '停止标志', '停车计时器', '长椅', '鸟', '猫', '狗',
  '马', '羊', '牛', '大象', '熊', '斑马', '长颈鹿', '背包', '雨伞',
  '手提包', '领带', '行李箱', '飞盘', '滑雪板', '单板滑雪', '运动球',
  '风筝', '棒球棒', '棒球手套', '滑板', '冲浪板', '网球拍', '瓶子',
  '红酒杯', '杯子', '叉子', '刀', '勺子', '碗', '香蕉', '苹果',
  '三明治', '橙子', '西兰花', '胡萝卜', '热狗', '披萨', '甜甜圈',
  '蛋糕', '椅子', '沙发', '盆栽', '床', '餐桌', '马桶', '电视',
  '笔记本电脑', '鼠标', '遥控器', '键盘', '手机', '微波炉', '烤箱',
  '烤面包机', '水槽', '冰箱', '书', '时钟', '花瓶', '剪刀', '泰迪熊',
  '吹风机', '牙刷'
];

export interface BoundingBox {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface DetectedObject {
  label: string;
  labelId: number;
  score: number;
  box: BoundingBox;
  speechText?: string;
}

export class YoloDetector {
  private model: mindSporeLite.Model | null = null;
  private context: common.UIAbilityContext;
  private readonly MODEL_NAME: string = 'yolov8n.ms';
  private readonly INPUT_SIZE: number = 640;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async loadModel(): Promise<boolean> {
    try {
      const rawFileContent: Uint8Array = await this.context.resourceManager.getRawFileContent(this.MODEL_NAME);
      const modelBuffer: ArrayBuffer = rawFileContent.buffer as ArrayBuffer;

      const cpuConfig: mindSporeLite.CpuDevice = {
        threadNum: 4,
        threadAffinityMode: mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST,
        precisionMode: 'enforce_fp32'
      };
      const msContext: mindSporeLite.Context = { target: ['cpu'], cpu: cpuConfig };

      this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer, msContext);
      hilog.info(0xFF00, 'YoloDetector', '80类模型加载成功（CPU）');
      return true;
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0xFF00, 'YoloDetector', `模型加载失败: code=${e.code}, message=${e.message}`);
      return false;
    }
  }

  async detect(inputBuffer: Float32Array): Promise<DetectedObject[]> {
    if (this.model === null || !inputBuffer) return [];

    try {
      const modelInputs: mindSporeLite.MSTensor[] = this.model.getInputs();
      if (!modelInputs || modelInputs.length === 0) return [];
      modelInputs[0].setData(inputBuffer.buffer);

      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(modelInputs);
      if (!outputs || outputs.length === 0) return [];

      return this.parseOutput(outputs);
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0xFF00, 'YoloDetector', `推理失败: code=${e.code}`);
      return [];
    }
  }

  private parseOutput(outputs: mindSporeLite.MSTensor[]): DetectedObject[] {
    if (!outputs || outputs.length === 0) return [];
    const rawData = outputs[0].getData();
    if (!rawData) return [];

    const outputData = new Float32Array(rawData);
    const numClasses = 80;
    const results: DetectedObject[] = [];

    const CONF_THRESHOLD = 0.6;

    for (let i = 0; i < NUM_BOXES; i++) {
      let maxClassScore = 0;
      let maxClassId = -1;
      for (let c = 0; c < numClasses; c++) {
        const classScore = outputData[(4 + c) * NUM_BOXES + i];
        if (classScore > maxClassScore) {
          maxClassScore = classScore;
          maxClassId = c;
        }
      }

      if (maxClassScore < CONF_THRESHOLD || maxClassId < 0) continue;

      let label = '障碍物';
      if (maxClassId < COCO_LABELS.length) {
        label = COCO_LABELS[maxClassId];
      }

      let isIgnored = false;
      for (let kw of IGNORED_KEYWORDS) {
        if (label.includes(kw)) {
          isIgnored = true;
          break;
        }
      }
      if (isIgnored) continue;

      // 【核心修复 1】：直接取归一化值，不再除以 INPUT_SIZE
      const cx = outputData[0 * NUM_BOXES + i];
      const cy = outputData[1 * NUM_BOXES + i];
      const w = outputData[2 * NUM_BOXES + i];
      const h = outputData[3 * NUM_BOXES + i];

      // 归一化后的宽高不可能大于 1.5（留点容错），也不可能 <= 0
      if (w <= 0 || h <= 0 || w > 1.5 || h > 1.5) continue;

      results.push({
        label: label,
        labelId: maxClassId,
        score: maxClassScore,
        box: { left: cx - w / 2, top: cy - h / 2, width: w, height: h }
      });
    }

    results.sort((a, b) => b.score - a.score);

    // 【核心修复 2】：NMS 必须分门别类，人和椅子重叠不能互删
    const nmsResults: DetectedObject[] = [];
    for (let i = 0; i < results.length; i++) {
      let keep = true;
      for (let j = 0; j < nmsResults.length; j++) {

        // 只有类别 ID 相同的时候，才进行重叠度判定
        if (results[i].labelId === nmsResults[j].labelId) {
          const boxA = results[i].box;
          const boxB = nmsResults[j].box;
          const xA = Math.max(boxA.left, boxB.left);
          const yA = Math.max(boxA.top, boxB.top);
          const xB = Math.min(boxA.left + boxA.width, boxB.left + boxB.width);
          const yB = Math.min(boxA.top + boxA.height, boxB.top + boxB.height);

          const interArea = Math.max(0, xB - xA) * Math.max(0, yB - yA);
          const unionArea = boxA.width * boxA.height + boxB.width * boxB.height - interArea;
          const iou = unionArea > 0 ? interArea / unionArea : 0;

          // 同类别的重复框，重叠度大于 0.45 就删掉
          if (iou > 0.45) {
            keep = false;
            break;
          }
        }
      }
      if (keep) nmsResults.push(results[i]);
    }
    return nmsResults;
  }

  release(): void {
    if (this.model !== null) this.model = null;
  }
}