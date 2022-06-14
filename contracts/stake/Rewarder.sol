// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "./MasterChef.sol";

interface IRewarder {
  using SafeERC20Upgradeable for IERC20Upgradeable;

  function onFullReward(address user, uint256 newLpAmount) external;

  function pendingTokens(address user) external view returns (uint256 pending);

  function rewardToken() external view returns (IERC20Upgradeable);
}

contract Rewarder is IRewarder, OwnableUpgradeable, ReentrancyGuardUpgradeable {
  using SafeMathUpgradeable for uint256;
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using AddressUpgradeable for address;

  /// @notice Info of each MasterChef user.
  /// `amount` LP token amount the user has provided.
  /// `rewardDebt` The amount of YOUR_TOKEN entitled to the user.
  struct UserInfo {
    uint256 amount;
    uint256 rewardDebt;
    uint256 unpaidRewards;
  }

  /// @notice Info of each MasterChef poolInfo.
  /// `accTokenPerShare` Amount of YOUR_TOKEN each LP token is worth.
  /// `lastRewardTimestamp` The last timestamp YOUR_TOKEN was rewarded to the poolInfo.
  struct PoolInfo {
    uint256 accTokenPerShare;
    uint256 lastRewardTimestamp;
  }

  IERC20Upgradeable public override rewardToken;
  IERC20Upgradeable public lpToken;
  bool public isNative;
  MasterChef public mc;
  uint256 public tokenPerSec;

  // Given the fraction, tokenReward * ACC_TOKEN_PRECISION / lpSupply, we consider
  // several edge cases.
  //
  // Edge case n1: maximize the numerator, minimize the denominator.
  // `lpSupply` = 1 WEI
  // `tokenPerSec` = 1e(30)
  // `timeElapsed` = 31 years, i.e. 1e9 seconds
  // result = 1e9 * 1e30 * 1e36 / 1
  //        = 1e75
  // (No overflow as max uint256 is 1.15e77).
  // PS: This will overflow when `timeElapsed` becomes greater than 1e11, i.e. in more than 3_000 years
  // so it should be fine.
  //
  // Edge case n2: minimize the numerator, maximize the denominator.
  // `lpSupply` = max(uint112) = 1e34
  // `tokenPerSec` = 1 WEI
  // `timeElapsed` = 1 second
  // result = 1 * 1 * 1e36 / 1e34
  //        = 1e2
  // (Not rounded to zero, therefore ACC_TOKEN_PRECISION = 1e36 is safe)
  uint256 private constant ACC_TOKEN_PRECISION = 1e36;

  /// @notice Info of the poolInfo.
  PoolInfo public poolInfo;
  /// @notice Info of each user that stakes LP tokens.
  mapping(address => UserInfo) public userInfo;

  event OnReward(address indexed user, uint256 amount);
  event RewardRateUpdated(uint256 oldRate, uint256 newRate);

  modifier onlyMasterChef() {
    require(_msgSender() == address(mc), "onlyMasterChef: only MasterChef can call this function");
    _;
  }

  function initialize(
    IERC20Upgradeable _rewardToken,
    IERC20Upgradeable _lpToken,
    MasterChef _mc,
    bool _isNative,
    uint256 _tokenPerSec
  ) external initializer {
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    OwnableUpgradeable.__Ownable_init();

    // require(AddressUpgradeable.isContract(address(_rewardToken)), "initialize: reward token must be a valid contract");
    require(AddressUpgradeable.isContract(address(_lpToken)), "initialize: LP token must be a valid contract");
    require(AddressUpgradeable.isContract(address(_mc)), "initialize: MasterChef must be a valid contract");

    rewardToken = _rewardToken;
    lpToken = _lpToken;
    tokenPerSec = _tokenPerSec;
    mc = _mc;
    isNative = _isNative;
    poolInfo = PoolInfo({ lastRewardTimestamp: block.timestamp, accTokenPerShare: 0 });
  }

  /// @notice payable function needed to receive AVAX
  receive() external payable {}

  /// @notice Function called by MasterChef whenever staker claims FULL harvest. Allows staker to also receive a 2nd reward token.
  /// @param _user Address of user
  /// @param _lpAmount Number of LP tokens the user has
  function onFullReward(address _user, uint256 _lpAmount) external override onlyMasterChef nonReentrant {
    updatePool();
    PoolInfo memory pool = poolInfo;
    UserInfo storage user = userInfo[_user];
    uint256 pending;
    if (user.amount > 0) {
      pending = (user.amount.mul(pool.accTokenPerShare) / ACC_TOKEN_PRECISION).sub(user.rewardDebt).add(
        user.unpaidRewards
      );

      if (isNative) {
        uint256 balance = address(this).balance;
        if (pending > balance) {
          (bool success, ) = _user.call{ value: balance }("");
          require(success, "onFullReward: transfer failed");
          user.unpaidRewards = pending - balance;
        } else {
          (bool success, ) = _user.call{ value: pending }("");
          require(success, "onFullReward: transfer failed");
          user.unpaidRewards = 0;
        }
      } else {
        uint256 balance = rewardToken.balanceOf(address(this));
        if (pending > balance) {
          rewardToken.safeTransfer(_user, balance);
          user.unpaidRewards = pending - balance;
        } else {
          rewardToken.safeTransfer(_user, pending);
          user.unpaidRewards = 0;
        }
      }
    }

    user.amount = _lpAmount;
    user.rewardDebt = user.amount.mul(pool.accTokenPerShare) / ACC_TOKEN_PRECISION;
    emit OnReward(_user, pending - user.unpaidRewards);
  }

  /// @notice View function to see pending tokens
  /// @param _user Address of user.
  /// @return pending reward for a given user.
  function pendingTokens(address _user) external view override returns (uint256 pending) {
    PoolInfo memory pool = poolInfo;
    UserInfo storage user = userInfo[_user];

    uint256 accTokenPerShare = pool.accTokenPerShare;
    uint256 lpSupply = lpToken.balanceOf(address(mc));

    if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
      uint256 timeElapsed = block.timestamp.sub(pool.lastRewardTimestamp);
      uint256 tokenReward = timeElapsed.mul(tokenPerSec);
      accTokenPerShare = accTokenPerShare.add(tokenReward.mul(ACC_TOKEN_PRECISION).div(lpSupply));
    }

    pending = (user.amount.mul(accTokenPerShare) / ACC_TOKEN_PRECISION).sub(user.rewardDebt).add(user.unpaidRewards);
  }

  /// @notice View function to see balance of reward token.
  function balance() external view returns (uint256) {
    if (isNative) {
      return address(this).balance;
    } else {
      return rewardToken.balanceOf(address(this));
    }
  }

  /// @notice Sets the distribution reward rate. This will also update the poolInfo.
  /// @param _tokenPerSec The number of tokens to distribute per second
  function setRewardRate(uint256 _tokenPerSec) external onlyOwner {
    updatePool();

    uint256 oldRate = tokenPerSec;
    tokenPerSec = _tokenPerSec;

    emit RewardRateUpdated(oldRate, _tokenPerSec);
  }

  /// @notice Update reward variables of the given poolInfo.
  /// @return pool Returns the pool that was updated.
  function updatePool() public returns (PoolInfo memory pool) {
    pool = poolInfo;

    if (block.timestamp > pool.lastRewardTimestamp) {
      uint256 lpSupply = lpToken.balanceOf(address(mc));

      if (lpSupply > 0) {
        uint256 timeElapsed = block.timestamp.sub(pool.lastRewardTimestamp);
        uint256 tokenReward = timeElapsed.mul(tokenPerSec);
        pool.accTokenPerShare = pool.accTokenPerShare.add((tokenReward.mul(ACC_TOKEN_PRECISION) / lpSupply));
      }

      pool.lastRewardTimestamp = block.timestamp;
      poolInfo = pool;
    }
  }

  /// @notice In case rewarder is stopped before emissions finished, this function allows
  /// withdrawal of remaining tokens.
  function emergencyWithdraw() public onlyOwner {
    if (isNative) {
      (bool success, ) = _msgSender().call{ value: address(this).balance }("");
      require(success, "emergencyWithdraw: transfer failed");
    } else {
      rewardToken.safeTransfer(address(_msgSender()), rewardToken.balanceOf(address(this)));
    }
  }
}
