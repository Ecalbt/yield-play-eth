# YieldPlay - Giao thức Xổ số Không Mất Vốn

YieldPlay là một giao thức xổ số phi tập trung **không mất vốn**, nơi người dùng gửi tài sản vào các Round có thời hạn. Toàn bộ số tiền gửi được đưa vào các Strategy sinh lời (Aave, Compound, Yearn, v.v.) để tạo **yield**. Yield thu được sẽ tạo thành quỹ giải thưởng phân phối cho người thắng, trong khi **tất cả người gửi đều nhận lại đầy đủ số vốn gốc**.

## Mục lục

- [Tổng quan](#tổng-quan)
- [Kiến trúc](#kiến-trúc)
- [Cấu trúc Contract](#cấu-trúc-contract)
- [Vòng đời Round](#vòng-đời-round)
- [Cấu trúc Phí](#cấu-trúc-phí)
- [Hướng dẫn Sử dụng](#hướng-dẫn-sử-dụng)
- [Triển khai](#triển-khai)
- [Bảo mật](#bảo-mật)
- [Tham chiếu API](#tham-chiếu-api)

---

## Tổng quan

### Cách hoạt động

1. **Game Owner** tạo một Game với các tham số cấu hình (dev fee, payment token)
2. **Game Owner** tạo các Round với thời gian bắt đầu/kết thúc
3. **User** gửi token vào Round trong giai đoạn InProgress
4. **Game Owner** đưa tiền từ Round vào Strategy trong giai đoạn Locking để tạo yield
5. Sau giai đoạn khóa, **Game Owner** rút tiền và yield về lại contract
6. **Game Owner** thực hiện settlement (tính phí, lưu prize pool) và chọn Winner
7. **User** ở trạng thái thắng có thể claim vốn gốc + tiền thưởng; các user còn lại claim vốn gốc

### Tính năng chính

- 🔒 **No-Loss**: Tất cả depositor đều nhận lại principal (vốn gốc)
- 🎲 **Phân phối giải thưởng linh hoạt**: Game Owner tự quyết định logic chia prize pool
- 💰 **Tích hợp Strategy linh hoạt**: Hỗ trợ bất kỳ vault ERC4626 hoặc custom Strategy nào
- 🛡️ **Bảo mật theo best-practice**: ReentrancyGuard, Pausable, SafeERC20, Access Control rõ ràng
- ⛽ **Tối ưu gas**: Dùng custom errors, cấu trúc storage hợp lý

---

## Kiến trúc

```
┌─────────────────────────────────────────────────────────────────┐
│                         YieldPlay.sol                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Games     │  │   Rounds    │  │    User Deposits        │  │
│  │ mapping     │  │  mapping    │  │      mapping            │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      IYieldStrategy                             │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐   │
│  │  ERC4626Strategy    │  │     MockYieldStrategy           │   │
│  │  (Aave, Yearn...)   │  │     (Chỉ dùng test)             │   │
│  └─────────────────────┘  └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Cấu trúc Contract

```
contracts/
├── YieldPlay.sol                 # Contract giao thức chính
├── interfaces/
│   └── IYieldStrategy.sol        # Interface chiến lược
├── libraries/
│   ├── DataTypes.sol             # Structs và enums
│   └── Errors.sol                # Custom errors
├── strategies/
│   └── ERC4626Strategy.sol       # Adapter vault ERC4626
└── mocks/
    ├── MockERC20.sol             # Token mock phục vụ test
    └── MockYieldStrategy.sol     # Strategy mock phục vụ test
```

---

## Vòng đời Round

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────────────┐    ┌──────────────────────┐
│  NotStarted  │───►│  InProgress  │───►│   Locking    │───►│  ChoosingWinners  │───►│  DistributingRewards │
│              │    │              │    │              │    │                   │    │                      │
│  Round       │    │  User gửi    │    │  Tài sản     │    │  Đã rút tài sản   │    │  User claim          │
│  được tạo    │    │  deposit     │    │  trong Strategy│  │  + yield về vault │    │  principal + reward  │
└──────────────┘    └──────────────┘    └──────────────┘    └───────────────────┘    └──────────────────────┘
     │                    │                   │                      │                        │
     │                    │                   │                      │                        │
    now < startTs    startTs ≤ now ≤ endTs   endTs < now ≤         now > endTs +           Tùy logic Game Owner
                                                          endTs + lockTime       lockTime               (thường là đã chia xong)
```

### Chuyển đổi trạng thái Round

| Trạng thái | Mô tả | Hành động chính |
|-----------|-------|-----------------|
| `NotStarted` | Round đã tồn tại nhưng chưa bắt đầu | - |
| `InProgress` | Mở cho user deposit | `deposit()` |
| `Locking` | Đóng deposit, chuẩn bị/đang deploy sang Strategy | `depositToStrategy()` |
| `ChoosingWinners` | Đã rút tài sản từ Strategy, tính toán yield và chọn Winner | `withdrawFromStrategy()`, `settlement()`, `chooseWinner()` |
| `DistributingRewards` | Mở cho user claim principal + reward | `claim()` |

---

## Cấu trúc Phí

```
Tổng Yield
    │
    ├── 20% ──► Protocol Treasury (Performance Fee)
    │
    └── 80% ──► Net Yield
                    │
                    ├── X% ──► Game Treasury (Dev Fee, configurable 0-100%)
                    │
                    └── Phần còn lại ──► Prize Pool (chia cho Winner)
```

**Ví dụ**: Yield = 1000 USDC, dev fee = 10%
- Performance Fee: 200 USDC (20%)
- Dev Fee: 80 USDC (10% của 800)
- Prize Pool: 720 USDC

---

## Hướng dẫn Sử dụng

### Dành cho Game Owner

#### 1. Tạo Game

```solidity
bytes32 gameId = yieldPlay.createGame(
    "MyLottery",           // gameName
    1000,                  // devFeeBps (10% = 1000)
    treasuryAddress,       // địa chỉ treasury nhận dev fee
    usdcAddress            // payment token
);
```

#### 2. Tạo Round

```solidity
uint256 roundId = yieldPlay.createRound(
    gameId,
    uint64(block.timestamp + 1 hours),   // startTs - thời điểm Round bắt đầu nhận deposit
    uint64(block.timestamp + 1 days),    // endTs - thời điểm đóng deposit
    uint64(12 hours)                     // lockTime - thời gian khóa sau khi endTs
);
```

#### 3. Quản lý vòng đời Round

```solidity
// Sau khi đóng deposit, deploy funds sang Strategy
yieldPlay.depositToStrategy(gameId, roundId);

// Sau giai đoạn khóa, rút tài sản + yield từ Strategy về contract
yieldPlay.withdrawFromStrategy(gameId, roundId);

// Settlement: tính toán phí, cập nhật prizePool
yieldPlay.settlement(gameId, roundId);

// Chọn Winner và phân bổ prizePool cho từng Winner
yieldPlay.chooseWinner(gameId, roundId, winnerAddress, prizeAmount);

// Hoặc kết thúc Round mà không cần dùng hết prizePool
yieldPlay.finalizeRound(gameId, roundId);
```

### Dành cho User

#### Gửi tiền (deposit)

```solidity
// Approve trước cho YieldPlay
usdc.approve(yieldPlayAddress, amount);

// Gửi tiền
yieldPlay.deposit(gameId, roundId, amount);
```

#### Nhận tiền (claim)

```solidity
// Sau khi round ở trạng thái DistributingRewards
yieldPlay.claim(gameId, roundId);
```

### Hàm xem thông tin

```solidity
// Lấy thông tin game
Game memory game = yieldPlay.getGame(gameId);

// Lấy thông tin round
Round memory round = yieldPlay.getRound(gameId, roundId);

// Lấy thông tin gửi tiền của user
UserDeposit memory deposit = yieldPlay.getUserDeposit(gameId, roundId, userAddress);

// Lấy trạng thái hiện tại
RoundStatus status = yieldPlay.getCurrentStatus(gameId, roundId);

// Tính game ID
bytes32 gameId = yieldPlay.calculateGameId(ownerAddress, "gameName");
```

---

## Triển khai

### Yêu cầu

```bash
npm install
cp .env.example .env
# Chỉnh sửa .env với private key và RPC URLs của bạn
```

### Phát triển local

```bash
# Terminal 1: Chạy local node
npm run node

# Terminal 2: Deploy
npm run deploy:local
```

### Triển khai testnet

```bash
# Sepolia
npm run deploy:testnet

# Base Sepolia
npm run deploy:base
```

### Xác minh contract

```bash
npx hardhat verify --network sepolia <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

---

## Bảo mật

### Tính năng bảo mật

| Tính năng | Mô tả |
|-----------|-------|
| **ReentrancyGuard** | Bảo vệ chống reentrancy cho các hàm external quan trọng |
| **SafeERC20** | Thao tác ERC20 an toàn, hỗ trợ cả token không chuẩn |
| **Pausable** | Cho phép pause/unpause toàn bộ giao thức khi khẩn cấp |
| **Custom Errors** | Giảm gas so với require string, thông báo lỗi rõ ràng |
| **CEI Pattern** | Tuân thủ thứ tự Checks → Effects → Interactions |
| **Access Control** | Tách bạch vai trò Protocol Owner và Game Owner |

### Ma trận quyền truy cập

| Hàm | Protocol Owner | Game Owner | User |
|-----|--------------|----------|------------|
| `pause/unpause` | ✅ | ❌ | ❌ |
| `setStrategy` | ✅ | ❌ | ❌ |
| `setProtocolTreasury` | ✅ | ❌ | ❌ |
| `createGame` | ❌ | ✅ | ✅ |
| `createRound` | ❌ | ✅ | ❌ |
| `depositToStrategy` | ❌ | ✅ | ❌ |
| `withdrawFromStrategy` | ❌ | ✅ | ❌ |
| `settlement` | ❌ | ✅ | ❌ |
| `chooseWinner` | ❌ | ✅ | ❌ |
| `deposit` | ❌ | ❌ | ✅ |
| `claim` | ❌ | ❌ | ✅ |

---

## Tham chiếu API

### Events

```solidity
event GameCreated(bytes32 indexed gameId, address indexed owner, string gameName, uint16 devFeeBps, address paymentToken);
event RoundCreated(bytes32 indexed gameId, uint256 indexed roundId, uint64 startTs, uint64 endTs, uint64 lockTime);
event Deposited(bytes32 indexed gameId, uint256 indexed roundId, address indexed user, uint256 amount);
event FundsDeployed(bytes32 indexed gameId, uint256 indexed roundId, uint256 amount);
event FundsWithdrawn(bytes32 indexed gameId, uint256 indexed roundId, uint256 principal, uint256 yield);
event RoundSettled(bytes32 indexed gameId, uint256 indexed roundId, uint256 totalYield, uint256 performanceFee, uint256 devFee, uint256 prizePool);
event WinnerChosen(bytes32 indexed gameId, uint256 indexed roundId, address indexed winner, uint256 amount);
event Claimed(bytes32 indexed gameId, uint256 indexed roundId, address indexed user, uint256 principal, uint256 prize);
```

### Errors

```solidity
error InvalidDevFeeBps();          // devFeeBps không hợp lệ
error InvalidPaymentToken();       // paymentToken không hợp lệ
error InvalidRoundTime();          // Tham số thời gian Round không hợp lệ
error Unauthorized();              // Caller không có quyền thực hiện hành động
error RoundNotActive();            // Round không ở trạng thái cho phép hành động
error NoDepositsFound();           // User không có deposit trong Round
error RoundNotCompleted();         // Round chưa ở trạng thái hoàn tất
error AlreadyClaimed();            // User đã claim trước đó
error InvalidAmount();             // amount không hợp lệ (bằng 0, v.v.)
error StrategyCallFailed();        // Gọi Strategy bên ngoài thất bại
error RoundNotEnded();             // Round chưa kết thúc (chưa tới ChoosingWinners)
error NoFarmedAmount();            // Không có yield để phân phối
error RoundAlreadySettled();       // Round đã settlement trước đó
error RoundNotSettled();           // Round chưa settlement
error GameAlreadyExists();         // Game đã tồn tại với gameId này
error GameNotFound();              // Không tìm thấy Game tương ứng
error RoundNotFound();             // Không tìm thấy Round tương ứng
error FundsAlreadyDeployed();      // Funds đã được deploy sang Strategy
error FundsNotDeployed();          // Funds chưa được deploy sang Strategy
error StrategyNotSet();            // Chưa cấu hình Strategy cho paymentToken này
error ZeroAddress();               // Tham số address là address(0)
error InsufficientPrizePool();     // prizePool không đủ cho amount yêu cầu
```

---

## Kiểm thử

```bash
# Chạy tất cả tests
npm run test

# Chạy với báo cáo gas
npm run test:gas

# Chạy với coverage
npm run test:coverage
```

### Phạm vi test

- ✅ Tạo Game và validate tham số
- ✅ Tạo Round và kiểm tra chuyển trạng thái
- ✅ Deposit trong giai đoạn InProgress
- ✅ Toàn bộ vòng đời Round end-to-end
- ✅ Nhiều Winner trong cùng một Round
- ✅ Kiểm soát quyền truy cập cho Game Owner / Protocol Owner
- ✅ Hành vi các hàm admin
- ✅ Các hàm view

---

## Giấy phép

MIT
