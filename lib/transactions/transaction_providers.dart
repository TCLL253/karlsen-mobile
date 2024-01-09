import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_providers.dart';
import '../database/boxes.dart';
import '../karlsen/karlsen.dart';
import '../utxos/utxos_providers.dart';
import '../wallet/wallet_types.dart';
import '../wallet_address/wallet_address_providers.dart';
import '../wallet_auth/wallet_auth_providers.dart';
import '../wallet_balance/wallet_balance_providers.dart';
import 'transaction_notifier.dart';
import 'transaction_types.dart';
import 'tx_cache_service.dart';

// All new transactions from karlsen node
final _newTransactionProvider = StreamProvider.autoDispose((ref) {
  final client = ref.watch(karlsenClientProvider);

  final newBlock = client.notifyBlockAdded();

  return newBlock.expand(
    (message) => message.block.transactions.map((rpcTx) {
      var apiTx = ApiTransaction.fromRpc(rpcTx);
      if (message.block.verboseData.isChainBlock) {
        apiTx = apiTx.copyWith(isAccepted: true);
      }
      return apiTx;
    }),
  );
});

// New transactions associated with this wallet
final _newWalletTransactionProvider = StreamProvider.autoDispose((ref) {
  final controller = StreamController<ApiTransaction>();
  ref.listen(_newTransactionProvider, (_, next) {
    final result = next.whenOrNull(data: (tx) {
      final addressNotifier = ref.read(addressNotifierProvider);
      final utxosNotifier = ref.read(utxoNotifierProvider);

      final isWalletTx = tx.outputs.any((output) {
            final address = output.scriptPublicKeyAddress;
            return addressNotifier.containsAddress(address);
          }) ||
          tx.inputs.any((input) {
            final outpoint = Outpoint(
              transactionId: input.previousOutpointHash,
              index: input.previousOutpointIndex.toInt(),
            );
            return utxosNotifier.isWalletOutpoint(outpoint);
          });
      return isWalletTx ? tx : null;
    });

    if (result != null) {
      controller.add(result);
    }
  });

  ref.onDispose(controller.close);

  return controller.stream;
});

final _acceptedTransactionIdsProvider = StreamProvider.autoDispose((ref) {
  final client = ref.watch(karlsenClientProvider);
  return client
      .notifyVirtualSelectedParentChainChanged(
    includeAcceptedTransactionIds: true,
  )
      .expand((message) {
    return message.acceptedTransactionIds;
  });
});

final _txBoxProvider =
    Provider.autoDispose.family<LazyTypedBox<Tx>, WalletInfo>((ref, wallet) {
  final db = ref.watch(dbProvider);
  final network = ref.watch(networkProvider);

  final txBoxKey = wallet.boxInfo.getBoxInfo(network).tx.boxKey;
  return db.getLazyTypedBox<Tx>(txBoxKey);
});

final _txIndexBoxProvider = Provider.autoDispose
    .family<IndexedTypedBox<TxIndex>, WalletInfo>((ref, wallet) {
  final db = ref.watch(dbProvider);
  final network = ref.watch(networkProvider);

  final txIndexBoxKey = wallet.getBoxInfo(network).txIndex.boxKey;
  return db.getIndexedTypedBox<TxIndex>(txIndexBoxKey);
});

final txCacheServiceProvider =
    Provider.autoDispose.family<TxCacheService, WalletInfo>((ref, wallet) {
  final txIndexBox = ref.watch(_txIndexBoxProvider(wallet));
  final txBox = ref.watch(_txBoxProvider(wallet));
  final log = ref.watch(loggerProvider);

  final txCache = TxCacheService(
    txIndexBox: txIndexBox,
    txBox: txBox,
    log: log,
  );

  ref.listen(
    karlsenApiServiceProvider,
    (_, api) => txCache.api = api,
    fireImmediately: true,
  );

  return txCache;
});

final txNotifierForWalletProvider = ChangeNotifierProvider.autoDispose
    .family<TransactionNotifier, WalletInfo>((ref, wallet) {
  final service = ref.watch(txCacheServiceProvider(wallet));
  final log = ref.watch(loggerProvider);

  final notifier = TransactionNotifier(cache: service);
  notifier.loadMore();

  // Refresh transactions when balance changes
  ref.listen(lastBalanceChangesProvider, (_, next) {
    if (next.isEmpty) {
      return;
    }
    notifier.fetchNewTxsForAddresses(next.keys);
  }, fireImmediately: true);

  // Cache new transactions
  ref.listen(_newTransactionProvider, (_, next) {
    if (next.asData?.value case final tx?) {
      notifier.addToMemcache(tx);
    }
  });

  // Add new wallet transactions
  ref.listen(_newWalletTransactionProvider, (_, next) {
    if (next.asData?.value case final tx?) {
      log.d('New wallet tx: $tx');
      notifier.addWalletTx(tx);
    }
  });

  // Update transaction status
  ref.listen(_acceptedTransactionIdsProvider, (_, next) {
    if (next.asData?.value case final ids?) {
      final client = ref.read(karlsenClientProvider);

      notifier.processAcceptedTxIds(
        ids.acceptedTransactionIds,
        acceptingBlockHash: ids.acceptingBlockHash,
        client: client,
      );
    }
  });

  ref.onDispose(() {
    notifier.disposed = true;
  });

  return notifier;
});

final txNotifierProvider = Provider.autoDispose((ref) {
  final wallet = ref.watch(walletProvider);
  final txNotifier = ref.watch(txNotifierForWalletProvider(wallet));
  return txNotifier;
});

final txConfirmationStatusProvider =
    Provider.autoDispose.family<TxState, Tx>((ref, tx) {
  final blueScore = ref.watch(virtualSelectedParentBlueScoreProvider);

  final kNoConfirmations = BigInt.from(100);
  final txBlueScore = tx.apiTx.acceptingBlockBlueScore;

  if (!tx.apiTx.isAccepted || txBlueScore == null) {
    return const TxState.unconfirmed();
  }

  final confirmations = blueScore - BigInt.from(txBlueScore);
  if (confirmations >= kNoConfirmations) {
    return const TxState.confirmed();
  }

  return TxState.confirming(confirmations);
});
