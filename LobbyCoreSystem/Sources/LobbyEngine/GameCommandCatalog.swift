import Combine
import Foundation

// MARK: - 游戏指令库
//
// 抓包窗口的「指令库」页签 + 发送指令面板共用这份数据。
//
// 数据来源（三层）：
//   ① **已确认**：`/Users/gg/code/xyzw_web_helper` 的 `gameCommands.js`（mirror 代码
//      还原的完整实现，中文名 + 默认参数模板逐条对齐，37 条）；
//   ② **语义推断**：同一仓库批量任务代码里实际调用过的指令（~110 条，中文名按
//      上下文推断，标注 `inferred`，不保证与服务端语义逐字对应）；
//   ③ **自定义 / 自动发现**：用户手工添加，以及抓包流里出现的新 cmd 自动入库
//      （`discovered = true`，补了中文名后转为自定义）。
//
// 持久化：UserDefaults 单键 JSON（只存「用户层」——自定义 / 发现 / 对内置的改名，
// 内置表是代码常量，升级宿主时自动带上新指令）。
public struct GameCommandEntry: Codable, Identifiable, Equatable, Sendable {
    /// 指令字面值（BON 外层 `cmd`，如 `role_getroleinfo`）。
    public var command: String
    /// 中文名（发现态未命名时显示 cmd 本身）。
    public var chineseName: String
    /// 分组（系统 / 角色 / 英雄 / 军团 / …按 cmd 前缀归类）。
    public var category: String
    /// 默认参数模板（JSON 文本，发送面板可直接预填编辑）。
    public var defaultParamsJSON: String
    /// 来源：nil=内置确认 / `inferred`=语义推断 / `custom`=用户添加 / `discovered`=自动发现。
    public var origin: String?
    /// 备注。
    public var note: String

    public var id: String { command }

    /// 是否消耗资源的「高危」指令（购买 / 招募 / 抽取 / 消耗类，发送时红色警示）。
    public var isHighRisk: Bool {
        Self.isHighRiskCommand(command)
    }

    public init(command: String, chineseName: String, category: String,
                defaultParamsJSON: String = "{}", origin: String? = nil, note: String = "") {
        self.command = command
        self.chineseName = chineseName
        self.category = category
        self.defaultParamsJSON = defaultParamsJSON
        self.origin = origin
        self.note = note
    }

    /// 高危判定：参考 gameCommands.js 里会扣资源的调用。
    public static func isHighRiskCommand(_ command: String) -> Bool {
        let markers = ["buy", "recruit", "purchase", "lottery", "consume", "gacha", "rebirth", "openbox"]
        return markers.contains { command.localizedCaseInsensitiveContains($0) }
    }
}

/// 指令库（全局共享，跨账号 / 跨抓包窗口）。
@MainActor
public final class GameCommandStore: ObservableObject {
    /// UserDefaults 键。只存用户层条目（自定义 / 发现 / 内置改名）。
    private static let storageKey = "lobby.capture.commandCatalog.user"

    /// 内置表（代码常量，见文件头三层来源）。
    static let builtin: [GameCommandEntry] = {
        func e(_ command: String, _ name: String, _ category: String,
               _ params: String = "{}", inferred: Bool = false) -> GameCommandEntry {
            GameCommandEntry(command: command, chineseName: name, category: category,
                             defaultParamsJSON: params,
                             origin: inferred ? "inferred" : nil)
        }
        return [
            // ── ① 已确认（gameCommands.js，中文名与参数模板逐条对齐）──
            e("role_getroleinfo", "获取角色信息", "角色",
              "{\"clientVersion\":\"2.21.2-fa918e1997301834-wx\",\"inviteUid\":0,\"platform\":\"hortor\",\"platformExt\":\"mix\",\"scene\":\"\"}"),
            e("system_getdatabundlever", "获取数据包版本", "系统", "{\"isAudit\":false}"),
            e("system_buygold", "购买金币", "系统", "{\"buyNum\":1}"),
            e("system_mysharecallback", "分享回调", "系统", "{\"type\":3,\"isSkipShareCard\":true}"),
            e("system_claimhangupreward", "领取挂机奖励", "系统"),
            e("system_signinreward", "签到奖励", "系统"),
            e("friend_batch", "好友批处理", "好友", "{\"friendId\":0}"),
            e("hero_recruit", "英雄招募", "英雄", "{\"byClub\":false,\"recruitNumber\":1,\"recruitType\":3}"),
            e("item_openbox", "开宝箱", "道具", "{\"itemId\":2001,\"number\":10}"),
            e("arena_startarea", "开始竞技场", "竞技场"),
            e("arena_getareatarget", "获取竞技场目标", "竞技场", "{\"refresh\":false}"),
            e("fight_startareaarena", "开始竞技场战斗", "竞技场", "{\"targetId\":0,\"battleVersion\":0}"),
            e("store_goodslist", "获取商店商品列表", "商店", "{\"storeId\":1}"),
            e("store_buy", "商店购买", "商店", "{\"goodsId\":1}"),
            e("legion_storebuygoods", "军团商店购买", "军团"),
            e("store_refresh", "商店刷新", "商店", "{\"storeId\":1}"),
            e("bottlehelper_claim", "领取机器人助手奖励", "系统"),
            e("bottlehelper_start", "启动机器人助手", "系统", "{\"bottleType\":-1}"),
            e("bottlehelper_stop", "停止机器人助手", "系统", "{\"bottleType\":-1}"),
            e("artifact_lottery", "钓鱼", "神器", "{\"lotteryNumber\":1,\"newFree\":true,\"type\":1}"),
            e("task_claimdailypoint", "领取每日积分", "任务", "{\"taskId\":1}"),
            e("task_claimweekreward", "领取周奖励", "任务", "{\"rewardId\":0}"),
            e("task_claimdailyreward", "领取每日任务奖励", "任务", "{\"rewardId\":0}"),
            e("fight_startboss", "开始BOSS战", "战斗"),
            e("genie_sweep", "精灵扫荡", "精灵"),
            e("genie_buysweep", "购买精灵扫荡", "精灵"),
            e("discount_claimreward", "领取折扣奖励", "系统", "{\"discountId\":1}"),
            e("card_claimreward", "领取卡片奖励", "系统", "{\"cardId\":1}"),
            e("legion_signin", "军团签到", "军团"),
            e("fight_startlegionboss", "开始军团BOSS战", "战斗"),
            e("legion_getinfo", "获取军团信息", "军团"),
            e("legionmatch_rolesignup", "军团匹配角色报名", "军团"),
            e("fight_starttower", "开始爬塔", "战斗"),
            e("tower_claimreward", "领取爬塔奖励", "战斗"),
            e("tower_getinfo", "获取爬塔信息", "战斗"),
            e("study_startgame", "开始答题游戏", "答题"),
            e("study_answer", "答题", "答题", "{\"questionId\":0,\"answer\":1}"),
            e("study_claimreward", "领取答题奖励", "答题", "{\"rewardId\":1}"),
            e("mail_getlist", "获取邮件列表", "邮件", "{\"category\":[0,4,5],\"lastId\":0,\"size\":60}"),
            e("mail_claimallattachment", "领取所有邮件附件", "邮件", "{\"category\":0}"),
            e("legionwar_getdetails", "获取军团战详情", "军团", "{\"date\":\"2025/10/04\"}"),
            e("collection_claimfreereward", "领取珍宝阁免费奖励", "系统"),
            e("_sys/ack", "心跳应答", "系统"),
            e("heart_beat", "心跳", "系统"),

            // ── ② 语义推断（助手仓批量任务代码里实际调用过）──
            e("activity_get", "获取活动列表", "活动", inferred: true),
            e("activity_startactegame", "开始活动小游戏", "活动", inferred: true),
            e("activity_actegamestageclaim", "领取活动小游戏关卡奖励", "活动", inferred: true),
            e("activity_recyclewarorderrewardclaim", "领取回收战争令奖励", "活动", inferred: true),
            e("arena_getarearank", "获取竞技场排行", "竞技场", inferred: true),
            e("apex_getroleinfo", "获取巅峰角色信息", "竞猜", inferred: true),
            e("apex_getguesslist", "获取巅峰竞猜列表", "竞猜", inferred: true),
            e("apex_guess", "巅峰竞猜", "竞猜", inferred: true),
            e("artifact_load", "装备神器", "神器", inferred: true),
            e("artifact_unload", "卸下神器", "神器", inferred: true),
            e("artifact_exchange", "神器兑换", "神器", inferred: true),
            e("book_upgrade", "图鉴升级", "图鉴", inferred: true),
            e("book_claimpointreward", "领取图鉴积分奖励", "图鉴", inferred: true),
            e("bosstower_getinfo", "获取BOSS塔信息", "战斗", inferred: true),
            e("bosstower_startboss", "开始BOSS塔挑战", "战斗", inferred: true),
            e("bosstower_startbox", "开启BOSS塔宝箱", "战斗", inferred: true),
            e("bosstower_gethelprank", "获取BOSS塔协助排行", "战斗", inferred: true),
            e("car_getrolecar", "获取战车", "战车", inferred: true),
            e("car_send", "派出战车", "战车", inferred: true),
            e("car_claim", "领取战车奖励", "战车", inferred: true),
            e("car_refresh", "刷新战车", "战车", inferred: true),
            e("car_research", "战车研究", "战车", inferred: true),
            e("car_claimpartconsumereward", "领取战车部件消耗奖励", "战车", inferred: true),
            e("car_getmemberrank", "获取战车成员排行", "战车", inferred: true),
            e("car_getmemberhelpingcnt", "获取战车助力次数", "战车", inferred: true),
            e("collection_goodslist", "获取珍宝阁商品列表", "系统", inferred: true),
            e("discount_getdiscountinfo", "获取折扣信息", "系统", inferred: true),
            e("dungeon_buymerchant", "地牢商人购买", "地牢", inferred: true),
            e("dungeon_selecthero", "地牢选择英雄", "地牢", inferred: true),
            e("equipment_quench", "装备淬炼", "装备", inferred: true),
            e("equipment_confirm", "装备淬炼确认", "装备", inferred: true),
            e("equipment_updatequenchlock", "更新淬炼锁定", "装备", inferred: true),
            e("evotower_getinfo", "获取进化塔信息", "战斗", inferred: true),
            e("evotower_fight", "进化塔战斗", "战斗", inferred: true),
            e("evotower_readyfight", "进化塔准备战斗", "战斗", inferred: true),
            e("evotower_claimreward", "领取进化塔奖励", "战斗", inferred: true),
            e("evotower_claimtask", "领取进化塔任务", "战斗", inferred: true),
            e("evotower_getlegionjoinmembers", "获取进化塔军团成员", "战斗", inferred: true),
            e("fight_startdungeon", "开始地牢", "战斗", inferred: true),
            e("fight_startlevel", "开始关卡", "战斗", inferred: true),
            e("fight_startpvp", "开始PVP", "战斗", inferred: true),
            e("fight_level", "关卡战斗", "战斗", inferred: true),
            e("fight_calcleveltime", "计算关卡耗时", "战斗", inferred: true),
            e("gacha_drawreward", "抽卡领取奖励", "英雄", inferred: true),
            e("hero_heroupgradelevel", "英雄升级", "英雄", inferred: true),
            e("hero_heroupgradeorder", "英雄进阶", "英雄", inferred: true),
            e("hero_heroupgradestar", "英雄升星", "英雄", inferred: true),
            e("hero_rebirth", "英雄重生", "英雄", inferred: true),
            e("hero_gointobattle", "英雄上阵", "英雄", inferred: true),
            e("hero_gobackbattle", "英雄下阵", "英雄", inferred: true),
            e("hero_exchange", "英雄兑换", "英雄", inferred: true),
            e("item_consume", "使用道具", "道具", inferred: true),
            e("item_openpack", "开启礼包", "道具", inferred: true),
            e("item_batchclaimboxpointreward", "批量领取宝箱积分奖励", "道具", inferred: true),
            e("league_getbattlefield", "获取联赛战场", "联赛", inferred: true),
            e("league_getgroupopponent", "获取联赛分组对手", "联赛", inferred: true),
            e("legacy_getinfo", "获取遗迹信息", "遗迹", inferred: true),
            e("legacy_claimhangup", "领取遗迹挂机奖励", "遗迹", inferred: true),
            e("legacy_getgifts", "获取遗迹礼物", "遗迹", inferred: true),
            e("legacy_sendgift", "赠送遗迹礼物", "遗迹", inferred: true),
            e("legacy_gift_getlist", "获取可赠礼物列表", "遗迹", inferred: true),
            e("legacy_gift_received", "已收礼物列表", "遗迹", inferred: true),
            e("legion_agree", "同意军团申请", "军团", inferred: true),
            e("legion_refuseapply", "拒绝军团申请", "军团", inferred: true),
            e("legion_approveapply", "批准军团申请", "军团", inferred: true),
            e("legion_ignore", "忽略军团申请", "军团", inferred: true),
            e("legion_applylist", "获取军团申请列表", "军团", inferred: true),
            e("legion_kickout", "踢出军团成员", "军团", inferred: true),
            e("legion_research", "军团研究", "军团", inferred: true),
            e("legion_resetresearch", "重置军团研究", "军团", inferred: true),
            e("legion_signup", "军团报名", "军团", inferred: true),
            e("legion_getwarrank", "获取军团战排行", "军团", inferred: true),
            e("legion_getarearank", "获取军团竞技排行", "军团", inferred: true),
            e("legion_getbattlefield", "获取军团战场", "军团", inferred: true),
            e("legion_getopponent", "获取军团对手", "军团", inferred: true),
            e("legion_getinfobyid", "按ID获取军团信息", "军团", inferred: true),
            e("legion_payloadsignup", "军团货运报名", "军团", inferred: true),
            e("legion_getpayloadtask", "获取货运任务", "军团", inferred: true),
            e("legion_getpayloadbf", "获取货运战场", "军团", inferred: true),
            e("legion_getpayloadrecord", "获取货运记录", "军团", inferred: true),
            e("legion_getpayloadkillrecord", "获取货运击杀记录", "军团", inferred: true),
            e("legion_claimpayloadtask", "领取货运任务", "军团", inferred: true),
            e("legion_claimpayloadtaskprogress", "领取货运任务进度", "军团", inferred: true),
            e("lordweapon_changedefaultweapon", "更换默认领主武器", "装备", inferred: true),
            e("mail_getmtlinfo", "获取邮件附件详情", "邮件", inferred: true),
            e("mail_getmtlshortinfo", "获取邮件附件摘要", "邮件", inferred: true),
            e("matchteam_getroleteaminfo", "获取组队信息", "组队", inferred: true),
            e("mergebox_getinfo", "获取合成箱信息", "合成", inferred: true),
            e("mergebox_mergeitem", "合成物品", "合成", inferred: true),
            e("mergebox_automergeitem", "自动合成物品", "合成", inferred: true),
            e("mergebox_openbox", "合成箱开箱", "合成", inferred: true),
            e("mergebox_claimfreeenergy", "领取合成免费能量", "合成", inferred: true),
            e("mergebox_claimmergeprogress", "领取合成进度奖励", "合成", inferred: true),
            e("mergebox_claimcostprogress", "领取消耗进度奖励", "合成", inferred: true),
            e("nightmare_getroleinfo", "获取十殿角色信息", "十殿", inferred: true),
            e("pearl_exchangeskill", "交换珍珠技能", "装备", inferred: true),
            e("pearl_replaceskill", "替换珍珠技能", "装备", inferred: true),
            e("pearl_unloadskill", "卸下珍珠技能", "装备", inferred: true),
            e("presetteam_getinfo", "获取预设队伍", "组队", inferred: true),
            e("presetteam_saveteam", "保存预设队伍", "组队", inferred: true),
            e("presetteam_setteam", "设置预设队伍", "组队", inferred: true),
            e("rank_getserverrank", "获取服务器排行", "排行", inferred: true),
            e("rank_getroleinfo", "获取排行角色信息", "排行", inferred: true),
            e("saltroad_getwartype", "获取盐路战争类型", "盐路", inferred: true),
            e("saltroad_getsaltroadwargrouprank", "获取盐路分组排行", "盐路", inferred: true),
            e("saltroad_getsaltroadwartotalrank", "获取盐路总排行", "盐路", inferred: true),
            e("store_purchase", "商店购买(钻石)", "商店", inferred: true),
            e("system_custom", "自定义事件上报", "系统", inferred: true),
            e("system_hangupupgrade", "挂机升级", "系统", inferred: true),
            e("system_sendchatmessage", "发送聊天消息", "系统", inferred: true),
            e("towers_getinfo", "获取塔信息", "战斗", inferred: true),
            e("towers_start", "开始塔战斗", "战斗", inferred: true),
            e("towers_fight", "塔战斗", "战斗", inferred: true),
            e("war_enterbattlefield", "进入战场", "战斗", inferred: true),
            e("war_getbattlefieldinfo", "获取战场信息", "战斗", inferred: true),
            e("war_ping", "战场心跳", "战斗", inferred: true),
            e("warguess_startguess", "开始竞猜", "竞猜", inferred: true),
            e("warguess_getrank", "获取竞猜排行", "竞猜", inferred: true),
            e("warguess_getguesscoinreward", "领取竞猜币奖励", "竞猜", inferred: true),
            e("hero_gobackbattle", "英雄下阵", "英雄", inferred: true),
            e("fight_startpvp", "开始PVP战斗", "战斗", inferred: true),
        ]
    }()

    /// 全量条目（内置 + 用户层，用户层覆盖同名内置——允许给内置条目改名）。
    @Published public private(set) var entries: [GameCommandEntry] = []

    /// 用户层条目（自定义 / 发现 / 覆盖记录），落 UserDefaults。
    private var userEntries: [GameCommandEntry] = [] {
        didSet { persist() }
    }

    public init() {
        load()
        rebuild()
    }

    // MARK: - 查询

    public func lookup(_ command: String) -> GameCommandEntry? {
        entries.first { $0.command == command }
    }

    /// 展示名：命中 → 中文名；未命中 → cmd 本身。
    public func displayName(for command: String) -> String {
        lookup(command)?.chineseName ?? command
    }

    public var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    // MARK: - 增删改

    /// 抓包流发现的新 cmd（幂等；已存在的不动）。
    public func addDiscovered(_ command: String) {
        guard !command.isEmpty,
              lookup(command) == nil else { return }
        let entry = GameCommandEntry(command: command,
                                     chineseName: command,
                                     category: Self.categoryForCommand(command),
                                     origin: "discovered",
                                     note: "抓包自动发现，点击编辑补中文名")
        userEntries.append(entry)
        rebuild()
    }

    /// 新增 / 更新（按 command 判定同一条）。origin 归为 custom（发现条目补名后转正）。
    public func upsert(_ entry: GameCommandEntry) {
        var updated = entry
        updated.origin = "custom"
        if let index = userEntries.firstIndex(where: { $0.command == updated.command }) {
            userEntries[index] = updated
        } else {
            userEntries.append(updated)
        }
        rebuild()
    }

    /// 删除（仅用户层；内置条目不受影响——删了会被 rebuild 恢复）。
    public func remove(_ entry: GameCommandEntry) {
        userEntries.removeAll { $0.command == entry.command }
        rebuild()
    }

    // MARK: - 私有

    /// 合并内置与用户层（用户层优先），按 command 排序输出。
    private func rebuild() {
        var merged = Self.builtin
        for user in userEntries {
            if let index = merged.firstIndex(where: { $0.command == user.command }) {
                merged[index] = user
            } else {
                merged.append(user)
            }
        }
        entries = merged.sorted { $0.command < $1.command }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let stored = try? JSONDecoder().decode([GameCommandEntry].self, from: data) else { return }
        userEntries = stored
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(userEntries) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 按 cmd 前缀归组（自动发现 / 未填分组时兜底）。
    public static func categoryForCommand(_ command: String) -> String {
        switch command.split(separator: "_").first.map(String.init) {
        case "system", "sys", "activity", "collection", "discount", "bottlehelper": return "系统"
        case "role": return "角色"
        case "hero", "gacha": return "英雄"
        case "arena": return "竞技场"
        case "fight", "towers", "tower", "bosstower", "evotower", "war": return "战斗"
        case "store": return "商店"
        case "legion", "legionwar", "legionmatch", "league": return "军团"
        case "mail": return "邮件"
        case "task": return "任务"
        case "item", "mergebox": return "道具"
        case "artifact", "pearl", "equipment", "lordweapon": return "装备"
        case "genie": return "精灵"
        case "legacy": return "遗迹"
        case "car": return "战车"
        case "study": return "答题"
        case "rank", "saltroad": return "排行"
        case "friend", "matchteam", "presetteam": return "组队"
        case "dungeon": return "地牢"
        case "warguess", "apex": return "竞猜"
        case "nightmare": return "十殿"
        case "book": return "图鉴"
        default: return "其他"
        }
    }
}
