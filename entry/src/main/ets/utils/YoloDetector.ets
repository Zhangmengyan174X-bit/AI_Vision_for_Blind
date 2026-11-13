// utils/YoloDetector.ets
import { mindSporeLite } from '@kit.MindSporeLiteKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

const NUM_BOXES = 8400;
const NUM_CLASSES = 601;
const CONF_THRESHOLD = 0.35;

const OIV7_LABELS: string[] = [
  '手风琴', '胶带', '飞行器', '飞机', '闹钟', '羊驼', '救护车', '动物', '蚂蚁', '羚羊',
  '苹果', '犰狳', '洋蓟', '汽车零部件', '斧头', '背包', '百吉饼', '烘焙食品', '平衡木', '球',
  '气球', '香蕉', '创可贴', '班卓琴', '驳船', '桶', '棒球棒', '棒球手套', '蝙蝠（动物）', '浴室配件',
  '浴室柜', '浴缸', '烧杯', '熊', '床', '蜜蜂', '蜂巢', '啤酒', '甲虫', '甜椒',
  '腰带', '长椅', '自行车', '自行车头盔', '自行车车轮', '坐浴盆', '广告牌', '台球桌', '双筒望远镜', '鸟',
  '搅拌机', '蓝松鸦', '船', '炸弹', '书', '书柜', '靴子', '瓶子', '开瓶器', '弓箭',
  '碗', '保龄球设备', '盒子', '男孩', '胸罩', '面包', '公文包', '西兰花', '青铜雕塑', '棕熊',
  '建筑物', '公牛', '墨西哥卷饼', '公交车', '半身像', '蝴蝶', '卷心菜', '橱柜', '蛋糕', '蛋糕架',
  '计算器', '骆驼', '相机', '开罐器', '金丝雀', '蜡烛', '糖果', '大炮', '独木舟', '哈密瓜',
  '汽车', '食肉动物', '胡萝卜', '手推车', '卡式录音机', '城堡', '猫', '猫家具', '毛毛虫', '牛',
  '吊扇', '大提琴', '蜈蚣', '链锯', '椅子', '奶酪', '猎豹', '五斗柜', '鸡', '风铃',
  '凿子', '筷子', '圣诞树', '时钟', '衣柜', '衣物', '外套', '鸡尾酒', '鸡尾酒摇酒器', '椰子',
  '咖啡', '咖啡杯', '咖啡桌', '咖啡机', '硬币', '无花果', '普通向日葵', '电脑键盘', '电脑显示器', '电脑鼠标',
  '容器', '便利店', '曲奇饼干', '烹饪喷雾', '有线电话', '化妆品', '沙发', '台面', '牛仔帽', '螃蟹',
  '奶油', '板球', '鳄鱼', '牛角面包', '王冠', '拐杖', '黄瓜', '橱柜', '窗帘', '砧板',
  '匕首', '乳制品', '鹿', '书桌', '甜点', '尿布', '骰子', '数字时钟', '恐龙', '洗碗机',
  '狗', '狗床', '玩偶', '海豚', '门', '门把手', '甜甜圈', '蜻蜓', '抽屉', '连衣裙',
  '钻头（工具）', '饮料', '吸管', '鼓', '鸭子', '哑铃', '鹰', '耳环', '鸡蛋（食物）', '大象',
  '信封', '橡皮擦', '粉饼', '纸巾盒', '猎鹰', '时尚配饰', '快餐', '传真机', '软呢帽', '文件柜',
  '消防栓', '壁炉', '鱼', '旗帜', '手电筒', '花', '花盆', '长笛', '飞盘', '食物',
  '食品加工机', '橄榄球', '橄榄球头盔', '鞋类', '叉子', '喷泉', '狐狸', '薯条', '圆号', '青蛙',
  '水果', '煎锅', '家具', '芦笋', '燃气灶', '长颈鹿', '女孩', '眼镜', '手套', '山羊',
  '护目镜', '金鱼', '高尔夫球', '高尔夫球车', '贡多拉', '鹅', '葡萄', '葡萄柚', '研磨机', '鳄梨酱',
  '吉他', '吹风机', '发胶', '汉堡', '锤子', '仓鼠', '干手器', '手提包', '手枪', '斑海豹',
  '口琴', '竖琴', '大键琴', '帽子', '耳机', '加热器', '刺猬', '直升机', '头盔', '高跟鞋',
  '徒步装备', '河马', '家用电器', '蜂巢', '单杠', '马', '热狗', '房子', '室内植物', '人类手臂',
  '人类胡须', '人体', '人耳', '人眼', '人脸', '人脚', '人类头发', '人手', '人头', '人腿',
  '人嘴', '人鼻', '加湿器', '冰淇淋', '室内划船机', '婴儿床', '昆虫', '无脊椎动物', 'iPod', '等足目动物',
  '夹克', '按摩浴缸', '美洲豹（动物）', '牛仔裤', '水母', '水上摩托', '壶', '果汁', '袋鼠', '水壶',
  '厨房餐桌', '厨房电器', '厨房刀', '厨房用具', '厨房器皿', '风筝', '刀', '考拉', '梯子', '汤勺',
  '瓢虫', '台灯', '陆地交通工具', '灯笼', '笔记本电脑', '薰衣草（植物）', '柠檬', '豹', '灯泡', '电灯开关',
  '灯塔', '百合', '豪华轿车', '狮子', '口红', '蜥蜴', '龙虾', '双人沙发', '行李和包', '猞猁',
  '喜鹊', '哺乳动物', '男人', '芒果', '枫树', '沙锤', '海洋无脊椎动物', '海洋哺乳动物', '量杯', '机械风扇',
  '医疗设备', '麦克风', '微波炉', '牛奶', '迷你裙', '镜子', '导弹', '搅拌器', '搅拌碗', '手机',
  '猴子', '飞蛾和蝴蝶', '摩托车', '老鼠', '玛芬蛋糕', '马克杯', '骡子', '蘑菇', '乐器', '电子琴',
  '钉子（建筑）', '项链', '床头柜', '双簧管', '办公楼', '办公用品', '橙子', '管风琴（乐器）', '鸵鸟', '水獭',
  '烤箱', '猫头鹰', '牡蛎', '桨', '棕榈树', '煎饼', '熊猫', '裁纸刀', '纸巾', '降落伞',
  '停车计时器', '鹦鹉', '意大利面', '糕点', '桃子', '梨', '钢笔', '笔袋', '卷笔刀', '企鹅',
  '香水', '人', '个人护理用品', '个人漂浮装置', '钢琴', '野餐篮', '相框', '猪', '枕头', '菠萝',
  '水罐（容器）', '披萨', '披萨刀', '植物', '塑料袋', '盘子', '大浅盘', '管道设施', '北极熊', '石榴',
  '爆米花', '门廊', '豪猪', '海报', '土豆', '电源插头和插座', '高压锅', '椒盐卷饼', '打印机', '南瓜',
  '沙袋', '兔子', '浣熊', '球拍', '萝卜', '棘轮（装置）', '渡鸦', '鳐鱼和 skate', '小熊猫', '冰箱',
  '遥控器', '爬行动物', '犀牛', '步枪', '环形活页夹', '火箭', '轮滑鞋', '玫瑰', '橄榄球', '尺子',
  '沙拉', '盐和胡椒瓶', '凉鞋', '三明治', '茶碟', '萨克斯管', '秤', '围巾', '剪刀', '记分牌',
  '蝎子', '螺丝刀', '雕塑', '海狮', '海龟', '海鲜', '海马', '安全带', '赛格威', '托盘',
  '缝纫机', '鲨鱼', '绵羊', '架子', '贝类', '衬衫', '短裤', '霰弹枪', '淋浴', '虾',
  '水槽', '滑板', '滑雪板', '裙子', '头骨', '臭鼬', '摩天大楼', '慢炖锅', '零食', '蜗牛',
  '蛇', '单板滑雪板', '雪人', '雪地摩托', '扫雪机', '皂液器', '袜子', '沙发床', '墨西哥宽边帽', '麻雀',
  '锅铲', '香料架', '蜘蛛', '勺子', '运动器材', '运动服', '南瓜（植物）', '鱿鱼', '松鼠', '楼梯',
  '订书机', '海星', '健身车', '听诊器', '凳子', '停车标志', '草莓', '路灯', '担架', '工作室沙发',
  '潜艇', '潜艇三明治', '西装', '手提箱', '遮阳帽', '太阳镜', '冲浪板', '寿司', '天鹅', '泳帽',
  '游泳池', '泳装', '剑', '注射器', '桌子', '乒乓球拍', '平板电脑', '餐具', '墨西哥卷饼', '坦克',
  '水龙头', '水果挞', '出租车', '茶', '茶壶', '泰迪熊', '电话', '电视', '网球', '网球拍',
  '帐篷', '头冠', '蜱虫', '领带', '老虎', '锡罐', '轮胎', '烤面包机', '马桶', '卫生纸',
  '番茄', '工具', '牙刷', '火炬', '陆龟', '毛巾', '塔', '玩具', '交通信号灯', '交通标志',
  '火车', '训练凳', '跑步机', '树', '树屋', '三脚架', '长号', '裤子', '卡车', '小号',
  '火鸡', '乌龟', '雨伞', '独轮车', '厢式货车', '花瓶', '蔬菜', '车辆', '车辆牌照', '小提琴',
  '排球（球）', '华夫饼', '华夫饼机', '挂钟', '衣柜', '洗衣机', '垃圾桶', '手表', '水上交通工具', '西瓜',
  '武器', '鲸鱼', '车轮', '轮椅', '打蛋器', '白板', '柳树', '窗户', '百叶窗', '葡萄酒',
  '酒杯', '酒架', '冬瓜', '炒锅', '女人', '燃木炉', '啄木鸟', '蠕虫', '扳手', '斑马',
  '西葫芦'
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
  queuedAt?: number; // 【新增】用于记录入队时间
}

export class YoloDetector {
  private model: mindSporeLite.Model | null = null;
  private context: common.UIAbilityContext;
  private readonly MODEL_NAME: string = 'yolov8n-oiv7.ms';
  private readonly INPUT_SIZE: number = 640;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  async loadModel(): Promise<boolean> {
    if (OIV7_LABELS.length !== NUM_CLASSES || OIV7_LABELS[244] !== '耳机') {
      hilog.error(0xFF00, 'YoloDetector', '类别映射表异常');
      return false;
    }
    try {
      const rawFileContent: Uint8Array = await this.context.resourceManager.getRawFileContent(this.MODEL_NAME);

      // 【内存修复】使用 slice 确保拿到纯净的 buffer
      const modelBytes = rawFileContent.slice();
      const modelBuffer = modelBytes.buffer as ArrayBuffer;

      const cpuConfig: mindSporeLite.CpuDevice = {
        threadNum: 4,
        threadAffinityMode: mindSporeLite.ThreadAffinityMode.BIG_CORES_FIRST,
        precisionMode: 'enforce_fp32'
      };
      const msContext: mindSporeLite.Context = { target: ['cpu'], cpu: cpuConfig };

      this.model = await mindSporeLite.loadModelFromBuffer(modelBuffer, msContext);
      hilog.info(0xFF00, 'YoloDetector', 'OIV7 601类模型加载成功（CPU）');
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

      // 【内存修复】输入同样使用 slice
      // 【核心修复】强制校验输入长度，必须是 3 * 640 * 640 = 1228800
      if (inputBuffer.length !== 3 * 640 * 640) {
        hilog.error(0xFF00, 'YoloDetector', `输入长度错误: ${inputBuffer.length}`);
        return [];
      }

      // 【新增】校验 Tensor Shape
      const inputShape = modelInputs[0].shape;
      if (inputShape.length !== 4 || inputShape[0] !== 1 || inputShape[1] !== 3 || inputShape[2] !== 640 || inputShape[3] !== 640) {
        hilog.error(0xFF00, 'YOLO', `输入 Tensor 形状异常: ${inputShape.join(',')}`);
        return [];
      }

      const inputData = inputBuffer.slice();
      modelInputs[0].setData(inputData.buffer as ArrayBuffer);

      const outputs: mindSporeLite.MSTensor[] = await this.model.predict(modelInputs);
      if (!outputs || outputs.length === 0) return [];

      const output = outputs[0];
      const shape = output.shape;

      // 【输出校验】严格检查 [1, 605, 8400]
      if (shape.length !== 3 || shape[0] !== 1 || shape[1] !== NUM_CLASSES + 4 || shape[2] !== NUM_BOXES) {
        hilog.error(0xFF00, 'YOLO', `输出结构异常: ${shape.join(',')}`);
        return [];
      }

      return this.parseOutput(outputs);
    } catch (error) {
      const e = error as BusinessError;
      hilog.error(0xFF00, 'YoloDetector', `推理失败: code=${e.code}, message=${e.message}`);
      return [];
    }
  }

  private parseOutput(outputs: mindSporeLite.MSTensor[]): DetectedObject[] {
    if (!outputs || outputs.length === 0) return [];
    const rawData = outputs[0].getData();
    if (!rawData) return [];

    const outputData = new Float32Array(rawData);
    const expectedLength = (NUM_CLASSES + 4) * NUM_BOXES;
    if (outputData.length !== expectedLength) {
      hilog.error(0xFF00, 'YOLO', `输出数据长度异常: ${outputData.length}, 预期: ${expectedLength}`);
      return [];
    }
    const results: DetectedObject[] = [];

    // 【耳机专项监控】
    let bestHeadphoneScore = 0;
    for (let i = 0; i < NUM_BOXES; i++) {
      const score = outputData[244 * NUM_BOXES + i]; // ID 244 是耳机
      if (score > bestHeadphoneScore) {
        bestHeadphoneScore = score;
      }
    }
    if (bestHeadphoneScore > 0.1) {
      hilog.info(0xFF00, 'YOLO', `检测到耳机潜力，最高置信度: ${bestHeadphoneScore.toFixed(3)}`);
    }

    for (let i = 0; i < NUM_BOXES; i++) {
      let maxClassScore = 0;
      let maxClassId = -1;

      for (let c = 0; c < NUM_CLASSES; c++) {
        const classScore = outputData[(4 + c) * NUM_BOXES + i];
        if (classScore > maxClassScore) {
          maxClassScore = classScore;
          maxClassId = c;
        }
      }

      if (maxClassScore < CONF_THRESHOLD || maxClassId < 0) continue;

      let label = '障碍物';
      if (maxClassId < OIV7_LABELS.length) {
        label = OIV7_LABELS[maxClassId];
      }

      if (label.startsWith('物体') && label.length > 3) continue;

      // 坐标除以 640
      const cx = outputData[0 * NUM_BOXES + i] / this.INPUT_SIZE;
      const cy = outputData[1 * NUM_BOXES + i] / this.INPUT_SIZE;
      const w = outputData[2 * NUM_BOXES + i] / this.INPUT_SIZE;
      const h = outputData[3 * NUM_BOXES + i] / this.INPUT_SIZE;

      if (w <= 0 || h <= 0 || w > 1.5 || h > 1.5) continue;

      results.push({
        label: label,
        labelId: maxClassId,
        score: maxClassScore,
        box: { left: cx - w / 2, top: cy - h / 2, width: w, height: h }
      });
    }

    results.sort((a, b) => b.score - a.score);

    // 【性能优化】限制候选框数量，防止 CPU 卡顿
    const candidates = results.slice(0, 300);
    const nmsResults: DetectedObject[] = [];

    for (let i = 0; i < candidates.length; i++) {
      let keep = true;
      for (let j = 0; j < nmsResults.length; j++) {
        if (candidates[i].labelId === nmsResults[j].labelId) {
          const boxA = candidates[i].box;
          const boxB = nmsResults[j].box;

          const xA = Math.max(boxA.left, boxB.left);
          const yA = Math.max(boxA.top, boxB.top);
          const xB = Math.min(boxA.left + boxA.width, boxB.left + boxB.width);
          const yB = Math.min(boxA.top + boxA.height, boxB.top + boxB.height);

          const interArea = Math.max(0, xB - xA) * Math.max(0, yB - yA);
          const unionArea = boxA.width * boxA.height + boxB.width * boxB.height - interArea;
          const iou = unionArea > 0 ? interArea / unionArea : 0;

          if (iou > 0.45) {
            keep = false;
            break;
          }
        }
      }
      if (keep) {
        nmsResults.push(candidates[i]);
      }
    }
    return nmsResults;
  }

  release(): void {
    if (this.model !== null) this.model = null;
  }
}