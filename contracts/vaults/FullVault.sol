// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.12;

// import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./FullERC20.sol";
import "../interfaces/fullDAO/IStrategy.sol";
import "../token/FullToken.sol";
import "../stake/MasterChef.sol";

/**
 * @dev Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract FullVault is FullERC20, Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  // Info of each user.
  struct UserInfo {
    uint256 rewardDebt; // Reward debt.
  }

  struct StratCandidate {
    address implementation;
    uint256 proposedTime;
  }

  // MasterChef
  MasterChef public masterChef;
  // FullToken
  FullToken public full;
  // VaultId in MasterChef
  uint256 public vaultId;
  // Info of each user that stakes LP tokens.
  mapping(address => UserInfo) public userInfo;

  // The last proposed strategy to switch to.
  StratCandidate public stratCandidate;
  // The strategy currently in use by the vault.
  IStrategy public strategy;
  // The minimum time it has to pass before a strat candidate can be approved.
  uint256 public immutable approvalDelay;

  event NewStratCandidate(address implementation);
  event UpgradeStrat(address implementation);
  event Withdraw(address indexed user, address indexed stakeToken, uint256 amount);
  event Deposit(address indexed user, address indexed stakeToken, uint256 amount);
  event HarvestFull(address indexed user, address indexed stakeToken, uint256 reward);

  /**
   * @dev Sets the value of {token} to the token that the vault will
   * hold as underlying value. It initializes the vault's own 'fullvault' token.
   * This token is minted when someone does a deposit. It is burned in order
   * to withdraw the corresponding portion of the underlying assets.
   * @param _masterChef the address of the MasterChef.
   * @param _full the address of the Full token.
   * @param _vaultId vault id.
   * @param _strategy the address of the strategy.
   * @param _name the name of the vault token.
   * @param _symbol the symbol of the vault token.
   * @param _approvalDelay the delay before a new strat can be approved.
   */
  constructor(
    MasterChef _masterChef,
    FullToken _full,
    uint256 _vaultId,
    IStrategy _strategy,
    string memory _name,
    string memory _symbol,
    uint256 _approvalDelay
  ) public FullERC20(_name, _symbol) {
    masterChef = _masterChef;
    full = _full;
    vaultId = _vaultId;
    strategy = _strategy;
    approvalDelay = _approvalDelay;
  }

  // Get want of vault
  function want() public view returns (IERC20) {
    return IERC20(strategy.want());
  }

  // Get Full per second.
  function fullPerSec() public view returns (uint256) {
    (, , , uint256 allocPoint, , ) = masterChef.poolInfo(vaultId);
    uint256 totalAllocPoint = masterChef.totalAllocPoint();
    uint256 _fullPerSec = masterChef.fullPerSec();
    return _fullPerSec.mul(allocPoint).div(totalAllocPoint);
  }

  // Get pool accFullPerShare.
  function poolAccFullPerShare() public view returns (uint256 accFullPerShare) {
    (, accFullPerShare, , , , ) = masterChef.poolInfo(vaultId);
  }

  // View function to get pending rewads.
  function pendingReward(address _user) public view returns (uint256) {
    UserInfo storage user = userInfo[_user];
    (, , uint256 lastRewardTimestamp, uint256 allocPoint, , ) = masterChef.poolInfo(vaultId);
    uint256 totalAllocPoint = masterChef.totalAllocPoint();
    uint256 accFullPerShare = poolAccFullPerShare();
    uint256 _fullPerSec = masterChef.fullPerSec();
    if (block.timestamp > lastRewardTimestamp && totalSupply() != 0) {
      uint256 multiplier = block.timestamp.sub(lastRewardTimestamp);
      uint256 fullReward = multiplier.mul(_fullPerSec).mul(allocPoint).div(totalAllocPoint);
      accFullPerShare = accFullPerShare.add(fullReward.mul(1e12).div(totalSupply()));
    }
    return (balanceOf(_user).mul(accFullPerShare)).div(1e12).sub(user.rewardDebt);
  }

  // Update reward variables of the given vault to be up-to-date.
  function updatePool() public {
    masterChef.updateVault(vaultId);
  }

  // Harvest only Full earned from vault.
  function harvestFull() public {
    UserInfo storage user = userInfo[_msgSender()];
    require(balanceOf(_msgSender()) > 0, "harvestFull: nothing to harvest");
    updatePool();
    _harvestFull(_msgSender());
    user.rewardDebt = balanceOf(_msgSender()).mul(poolAccFullPerShare()).div(1e12);
  }

  // Harvest Full earned from vault.
  function _harvestFull(address _user) internal {
    UserInfo storage user = userInfo[_user];
    uint256 pending = balanceOf(_user).mul(poolAccFullPerShare()).div(1e12).sub(user.rewardDebt);
    require(pending <= full.balanceOf(address(this)), "_harvestFull: not enough Full");
    if (pending > 0) {
      _safeFullTransfer(_user, pending);
    }
    emit HarvestFull(_user, address(want()), pending);
  }

  /**
   * @dev It calculates the total underlying value of {token} held by the system.
   * It takes into account the vault contract balance, the strategy contract balance
   *  and the balance deployed in other contracts as part of the strategy.
   */
  function balance() public view returns (uint256) {
    return want().balanceOf(address(this)).add(IStrategy(strategy).balanceOf());
  }

  /**
   * @dev Custom logic in here for how much the vault allows to be borrowed.
   * We return 100% of tokens for now. Under certain conditions we might
   * want to keep some of the system funds at hand in the vault, instead
   * of putting them to work.
   */
  function available() public view returns (uint256) {
    return want().balanceOf(address(this));
  }

  /**
   * @dev Function for various UIs to display the current value of one of our yield tokens.
   * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
   */
  function getPricePerFullShare() public view returns (uint256) {
    return totalSupply() == 0 ? 1e18 : balance().mul(1e18).div(totalSupply());
  }

  /**
   * @dev A helper function to call deposit() with all the sender's funds.
   */
  function depositAll() external {
    deposit(want().balanceOf(_msgSender()));
  }

  /**
   * @dev The entrypoint of funds into the system. People deposit with this function
   * into the vault. The vault is then in charge of sending funds into the strategy.
   */
  function deposit(uint256 _amount) public nonReentrant {
    UserInfo storage user = userInfo[_msgSender()];
    strategy.beforeDeposit();

    uint256 _pool = balance();
    want().safeTransferFrom(_msgSender(), address(this), _amount);
    earn();
    uint256 _after = balance();
    _amount = _after.sub(_pool); // Additional check for deflationary tokens
    uint256 shares = 0;
    if (totalSupply() == 0) {
      shares = _amount;
    } else {
      shares = (_amount.mul(totalSupply())).div(_pool);
    }
    _mint(_msgSender(), shares);

    emit Deposit(_msgSender(), address(want()), _amount);
  }

  /**
   * @dev Function to send funds into the strategy and put them to work. It's primarily called
   * by the vault's deposit() function.
   */
  function earn() public {
    uint256 _bal = available();
    want().safeTransfer(address(strategy), _bal);
    strategy.deposit();
  }

  /**
   * @dev A helper function to call withdraw() with all the sender's funds.
   */
  function withdrawAll() external {
    withdraw(balanceOf(msg.sender));
  }

  /**
   * @dev Function to exit the system. The vault will withdraw the required tokens
   * from the strategy and pay up the token holder. A proportional number of IOU
   * tokens are burned in the process.
   */
  function withdraw(uint256 _shares) public {
    UserInfo storage user = userInfo[_msgSender()];

    uint256 r = (balance().mul(_shares)).div(totalSupply());
    _burn(_msgSender(), _shares);

    uint256 b = want().balanceOf(address(this));
    if (b < r) {
      uint256 _withdraw = r.sub(b);
      strategy.withdraw(_withdraw);
      uint256 _after = want().balanceOf(address(this));
      uint256 _diff = _after.sub(b);
      if (_diff < _withdraw) {
        r = b.add(_diff);
      }
    }

    want().safeTransfer(_msgSender(), r);

    emit Withdraw(_msgSender(), address(want()), balanceOf(_msgSender()));
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    updatePool();
    if (from != address(0)) {
      _harvestFull(from);
    }
    if (to != address(0) && balanceOf(to) > 0) {
      _harvestFull(to);
    }
  }

  function _afterTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    uint256 accFullPerShare = poolAccFullPerShare();
    if (from != address(0)) {
      userInfo[from].rewardDebt = balanceOf(from).mul(accFullPerShare).div(1e12);
    }
    if (to != address(0)) {
      userInfo[to].rewardDebt = balanceOf(to).mul(accFullPerShare).div(1e12);
    }
  }

  /**
   * @dev Sets the candidate for the new strat to use with this vault.
   * @param _implementation The address of the candidate strategy.
   */
  function proposeStrat(address _implementation) public onlyOwner {
    require(address(this) == IStrategy(_implementation).vault(), "Proposal not valid for this Vault");
    stratCandidate = StratCandidate({ implementation: _implementation, proposedTime: block.timestamp });

    emit NewStratCandidate(_implementation);
  }

  /**
   * @dev It switches the active strat for the strat candidate. After upgrading, the
   * candidate implementation is set to the 0x00 address, and proposedTime to a time
   * happening in +100 years for safety.
   */

  function upgradeStrat() public onlyOwner {
    require(stratCandidate.implementation != address(0), "There is no candidate");
    require(stratCandidate.proposedTime.add(approvalDelay) < block.timestamp, "Delay has not passed");

    emit UpgradeStrat(stratCandidate.implementation);

    strategy.retireStrat();
    strategy = IStrategy(stratCandidate.implementation);
    stratCandidate.implementation = address(0);
    stratCandidate.proposedTime = 5000000000;

    earn();
  }

  /**
   * @dev Rescues random funds stuck that the strat can't handle.
   * @param _token address of the token to rescue.
   */
  function inCaseTokensGetStuck(address _token) external onlyOwner {
    require(_token != address(want()), "!token");

    uint256 amount = IERC20(_token).balanceOf(address(this));
    IERC20(_token).safeTransfer(_msgSender(), amount);
  }

  // Safe Full transfer function, just in case if rounding error causes vault to not have enough FULLs.
  function _safeFullTransfer(address _to, uint256 _amount) internal {
    uint256 fullBal = full.balanceOf(address(this));
    if (_amount > fullBal) {
      full.transfer(_to, fullBal);
    } else {
      full.transfer(_to, _amount);
    }
  }
}
