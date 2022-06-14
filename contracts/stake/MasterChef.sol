// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import "../token/FullToken.sol";
import "./FDAO.sol";
import "./Rewarder.sol";
import "../interfaces/common/IFullVault.sol";

contract MasterChef is OwnableUpgradeable, AccessControlUpgradeable {
  using SafeMathUpgradeable for uint256;
  using SafeERC20Upgradeable for IERC20Upgradeable;
  using AddressUpgradeable for address;

  // Info of each user.
  struct UserInfo {
    uint256 amount; // How many LP tokens the user has provided.
    uint256 rewardDebt; // Reward debt. See explanation below.
    //
    // We do some fancy math here. Basically, any point in time, the amount of FULLs
    // entitled to a user but is pending to be distributed is:
    //
    //   pending reward = (user.amount * pool.accFullPerShare) - user.rewardDebt
    //
    // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
    //   1. The pool's `accFullPerShare` (and `lastRewardTimestamp`) gets updated.
    //   2. User receives the pending reward sent to his/her address.
    //   3. User's `amount` gets updated.
    //   4. User's `rewardDebt` gets updated.
  }

  // Info of each pool.
  struct PoolInfo {
    IERC20Upgradeable lpToken; // Address of LP token contract.
    uint256 accFullPerShare; // Accumulated FULLs per share, times 1e12. See below.
    uint256 lastRewardTimestamp; // Last timestamp that FULLs distribution occurs.
    uint256 allocPoint; // How many allocation points assigned to this pool. FULLs to distribute per second.
    IRewarder rewarder;
    IFullVault vault;
  }

  // FULL token.
  FullToken public full;
  // FDAO token.
  FDAO public fDAO;
  // FULL tokens created per second.
  uint256 public fullPerSec;

  // Info of each pool.
  PoolInfo[] public poolInfo;
  // Mapping to check which LP tokens have been added as pools.
  mapping(IERC20Upgradeable => bool) public isPool;
  // Info of each user that stakes LP tokens.
  mapping(uint256 => mapping(address => UserInfo)) public userInfo;
  // Total allocation points. Must be the sum of all allocation points in all pools.
  uint256 public totalAllocPoint;
  // The timestamp when FULL mining starts.
  uint256 public startTimestamp;

  event AddVault(uint256 indexed vaultId, uint256 allocPoint);
  event SetVault(uint256 indexed vaultId, uint256 allocPoint);

  event AddPool(uint256 indexed poolId, address indexed lpToken, uint256 allocPoint, IRewarder indexed rewarder);
  event SetPool(uint256 indexed poolId, address indexed lpToken, uint256 allocPoint, IRewarder indexed rewarder);

  event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed poolId, uint256 amount);
  event Harvest(address indexed user, uint256 indexed poolId, uint256 reward);
  event EmergencyWithdraw(address indexed user, uint256 indexed poolId, uint256 amount);

  event UpdateEmissionRate(address indexed user, uint256 fullPerSec);
  event MintVaultReward(uint256 indexed vaultId, uint256 amount);

  function initialize(
    FullToken _full,
    FDAO _fDAO,
    uint256 _fullPerSec,
    uint256 _startTimestamp
  ) external initializer {
    OwnableUpgradeable.__Ownable_init();
    AccessControlUpgradeable.__AccessControl_init();
    _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());

    full = _full;
    fDAO = _fDAO;
    fullPerSec = _fullPerSec;
    startTimestamp = _startTimestamp;
    totalAllocPoint = 0;
  }

  function poolLength() external view returns (uint256) {
    return poolInfo.length;
  }

  // Add a new vault.
  function _addVault(uint256 _allocPoint, IFullVault _vault) internal {
    massUpdatePools();
    uint256 lastRewardTimestamp = block.timestamp > startTimestamp ? block.timestamp : startTimestamp;
    totalAllocPoint = totalAllocPoint.add(_allocPoint);
    poolInfo.push(
      PoolInfo({
        lpToken: IERC20Upgradeable(address(0)),
        accFullPerShare: 0,
        lastRewardTimestamp: lastRewardTimestamp,
        allocPoint: _allocPoint,
        rewarder: IRewarder(address(0)),
        vault: _vault
      })
    );
    emit AddVault(poolInfo.length, _allocPoint);
  }

  // Update the given vault's FULL allocation point.
  function _setVault(uint256 _id, uint256 _allocPoint) internal {
    massUpdatePools();
    totalAllocPoint = totalAllocPoint.sub(poolInfo[_id].allocPoint).add(_allocPoint);
    poolInfo[_id].allocPoint = _allocPoint;
    emit SetVault(_id, _allocPoint);
  }

  // Add a new vault. Can only be called by the owner.
  function addVault(uint256 _allocPoint, IFullVault _vault) public onlyOwner {
    if (address(_vault) != address(0)) {
      uint256 vaultId = _vault.vaultId(); // sanity check
      require(vaultId == poolInfo.length, "addVault: vaultId not correct");
    }
    _addVault(_allocPoint, _vault);
  }

  // Update the given vault's FULL allocation point. Can only be called by the owner.
  function setVault(uint256 _id, uint256 _allocPoint) public onlyOwner {
    require(address(poolInfo[_id].vault) != address(0), "setVault: vault not exists");
    _setVault(_id, _allocPoint);
  }

  /// Add a new lp to the pool. Can only be called by the owner.
  /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
  /// @param _allocPoint AP of the new pool.
  /// @param _lpToken Address of the LP ERC-20 token.
  /// @param _rewarder Address of the rewarder delegate.
  function addPool(
    uint256 _allocPoint,
    IERC20Upgradeable _lpToken,
    IRewarder _rewarder
  ) public onlyOwner {
    require(!isPool[_lpToken], "addPool: LP already added");
    // Sanity check to ensure _lpToken is an ERC20 token
    _lpToken.balanceOf(address(this));
    // Sanity check if we add a rewarder
    if (address(_rewarder) != address(0)) {
      _rewarder.onFullReward(address(0), 0);
    }
    _addVault(_allocPoint, IFullVault(address(0)));
    uint256 id = poolInfo.length.sub(1);
    poolInfo[id].lpToken = _lpToken;
    poolInfo[id].accFullPerShare = 0;
    poolInfo[id].rewarder = _rewarder;
    isPool[_lpToken] = true;
    emit AddPool(id, address(_lpToken), _allocPoint, _rewarder);
  }

  // Update the given pool's FULL allocation point. Can only be called by the owner.
  function setPool(
    uint256 _id,
    uint256 _allocPoint,
    IRewarder _rewarder,
    bool overwrite
  ) public onlyOwner {
    PoolInfo storage pool = poolInfo[_id];
    require(isPool[pool.lpToken], "setPool: pool not exists");
    _setVault(_id, _allocPoint);
    if (overwrite) {
      _rewarder.onFullReward(address(0), 0); // sanity check
      pool.rewarder = _rewarder;
    }
    emit SetPool(_id, address(pool.lpToken), _allocPoint, overwrite ? _rewarder : pool.rewarder);
  }

  // View function to see pending FULLs on frontend.
  function pendingTokens(uint256 _id, address _user)
    external
    view
    returns (
      uint256 pendingFull,
      address bonusTokenAddress,
      uint256 pendingBonusToken
    )
  {
    PoolInfo storage pool = poolInfo[_id];
    UserInfo storage user = userInfo[_id][_user];
    uint256 accFullPerShare = pool.accFullPerShare;
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (block.timestamp > pool.lastRewardTimestamp && lpSupply != 0) {
      uint256 multiplier = block.timestamp.sub(pool.lastRewardTimestamp);
      uint256 fullReward = multiplier.mul(fullPerSec).mul(pool.allocPoint).div(totalAllocPoint);
      accFullPerShare = accFullPerShare.add(fullReward.mul(1e12).div(lpSupply));
    }
    pendingFull = user.amount.mul(accFullPerShare).div(1e12).sub(user.rewardDebt);

    // If it's a double reward farm, we return info about the bonus token
    if (address(pool.rewarder) != address(0)) {
      bonusTokenAddress = address(pool.rewarder.rewardToken());
      pendingBonusToken = pool.rewarder.pendingTokens(_user);
    }
  }

  // Update reward variables for all pools. Be careful of gas spending!
  function massUpdatePools() public {
    uint256 length = poolInfo.length;
    for (uint256 id = 0; id < length; id++) {
      updatePool(id);
    }
  }

  // Update reward variables of the given pool to be up-to-date.
  function updatePool(uint256 _id) public {
    PoolInfo storage pool = poolInfo[_id];
    if (block.timestamp <= pool.lastRewardTimestamp) {
      return;
    }
    if (address(pool.lpToken) == address(0) && address(pool.vault) != address(0)) {
      updateVault(_id);
      return;
    }
    uint256 lpSupply = pool.lpToken.balanceOf(address(this));
    if (lpSupply == 0) {
      pool.lastRewardTimestamp = block.timestamp;
      return;
    }
    uint256 multiplier = block.timestamp.sub(pool.lastRewardTimestamp);
    uint256 fullReward = multiplier.mul(fullPerSec).mul(pool.allocPoint).div(totalAllocPoint);
    full.mint(address(fDAO), fullReward);
    pool.accFullPerShare = pool.accFullPerShare.add(fullReward.mul(1e12).div(lpSupply));
    pool.lastRewardTimestamp = block.timestamp;
  }

  // Update reward variables of the given vault to be up-to-date.
  function updateVault(uint256 _id) public {
    PoolInfo storage pool = poolInfo[_id];
    if (block.timestamp <= pool.lastRewardTimestamp || address(pool.vault) == address(0)) {
      return;
    }
    uint256 vaultSupply = pool.vault.totalSupply();
    if (vaultSupply == 0) {
      pool.lastRewardTimestamp = block.timestamp;
      return;
    }
    uint256 multiplier = block.timestamp.sub(pool.lastRewardTimestamp);
    uint256 fullReward = multiplier.mul(fullPerSec).mul(pool.allocPoint).div(totalAllocPoint);
    full.mint(address(pool.vault), fullReward);
    pool.accFullPerShare = pool.accFullPerShare.add(fullReward.mul(1e12).div(vaultSupply));
    pool.lastRewardTimestamp = block.timestamp;
  }

  // Harvest Full earned from pools.
  function harvest(uint256[] calldata _ids) external {
    for (uint256 i = 0; i < _ids.length; i++) {
      harvest(_ids[i]);
    }
  }

  // Harvest Full earned from a specific pool.
  function harvest(uint256 _id) public {
    PoolInfo storage pool = poolInfo[_id];
    UserInfo storage user = userInfo[_id][_msgSender()];
    require(isPool[pool.lpToken], "harvest: pool not exists");
    updatePool(_id);
    _harvest(_id);
    user.rewardDebt = user.amount.mul(pool.accFullPerShare).div(1e12);
  }

  // Internal function to harvest Full
  function _harvest(uint256 _id) internal {
    PoolInfo memory pool = poolInfo[_id];
    UserInfo memory user = userInfo[_id][_msgSender()];
    require(user.amount > 0, "_harvest: nothing to harvest");
    uint256 pending = user.amount.mul(pool.accFullPerShare).div(1e12).sub(user.rewardDebt);
    _safeFullTransfer(_msgSender(), pending);
    fDAO.mint(_msgSender(), pending);
    emit Harvest(_msgSender(), _id, pending);
  }

  // Deposit LP tokens to MasterChef for FULL allocation.
  function deposit(uint256 _id, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_id];
    UserInfo storage user = userInfo[_id][_msgSender()];
    require(isPool[pool.lpToken], "deposit: pool not exists");
    updatePool(_id);
    if (user.amount > 0) _harvest(_id);
    if (_amount > 0) {
      pool.lpToken.safeTransferFrom(_msgSender(), address(this), _amount);
      user.amount = user.amount.add(_amount);
    }
    user.rewardDebt = user.amount.mul(pool.accFullPerShare).div(1e12);
    IRewarder _rewarder = pool.rewarder;
    if (address(_rewarder) != address(0)) {
      _rewarder.onFullReward(_msgSender(), user.amount);
    }
    emit Deposit(_msgSender(), _id, _amount);
  }

  // Withdraw LP tokens from MasterChef.
  function withdraw(uint256 _id, uint256 _amount) public {
    PoolInfo storage pool = poolInfo[_id];
    UserInfo storage user = userInfo[_id][_msgSender()];
    require(isPool[pool.lpToken], "withdraw: pool not exists");
    require(user.amount >= _amount, "withdraw: not good");
    updatePool(_id);
    _harvest(_id);
    if (_amount > 0) {
      user.amount = user.amount.sub(_amount);
      pool.lpToken.safeTransfer(address(_msgSender()), _amount);
    }
    user.rewardDebt = user.amount.mul(pool.accFullPerShare).div(1e12);
    IRewarder _rewarder = pool.rewarder;
    if (address(_rewarder) != address(0)) {
      _rewarder.onFullReward(_msgSender(), user.amount);
    }
    emit Withdraw(_msgSender(), _id, _amount);
  }

  // Withdraw without caring about rewards. EMERGENCY ONLY.
  function emergencyWithdraw(uint256 _id) public {
    PoolInfo storage pool = poolInfo[_id];
    UserInfo storage user = userInfo[_id][_msgSender()];
    require(isPool[pool.lpToken], "withdraw: pool not exists");
    user.amount = 0;
    user.rewardDebt = 0;
    IRewarder _rewarder = pool.rewarder;
    if (address(_rewarder) != address(0)) {
      _rewarder.onFullReward(_msgSender(), 0);
    }
    pool.lpToken.safeTransfer(address(_msgSender()), user.amount);
    emit EmergencyWithdraw(_msgSender(), _id, user.amount);
  }

  // Safe FULL transfer function, just in case if rounding error causes pool to not have enough FULLs.
  function _safeFullTransfer(address _to, uint256 _amount) internal {
    fDAO.safeFullTransfer(_to, _amount);
  }

  // Update emission rate
  function updateEmissionRate(uint256 _fullPerSec) public onlyOwner {
    massUpdatePools();
    fullPerSec = _fullPerSec;
    emit UpdateEmissionRate(_msgSender(), _fullPerSec);
  }
}
