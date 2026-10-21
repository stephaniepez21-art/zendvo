import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exceptions.dart';
import '../models/savings_data_model.dart';

/// Lifecycle of a savings transaction submission, used by UI controllers to
/// render the correct state and to revert cleanly after a permanent failure
/// instead of looping in a "pending" state.
enum SavingsSubmissionStatus {
  /// No submission is in flight.
  idle,

  /// The signed XDR is being submitted to the network.
  submitting,

  /// The submission succeeded and a transaction hash was returned.
  succeeded,

  /// The submission failed permanently; the user can retry.
  failed,
}

/// Handles API interactions for deposits, withdrawals, and polling balance.
///
/// All final XDR submission calls go through [ApiClient.postWithRetry], which
/// retries transient network failures with exponential backoff and maps
/// permanent failures to domain exceptions ([TransactionFailedException],
/// [NetworkCongestedException]) that UI controllers can surface to the user.
class SavingsRepository {
  SavingsRepository({
    ApiClient? apiClient,
    String? baseUrl,
    http.Client? client,
  })  : _apiClient = apiClient ?? ApiClient(),
        _baseUrl = baseUrl ?? defaultBaseUrl,
        httpClient = client ?? http.Client();

  /// Backend base URL; override with `--dart-define=API_BASE_URL=...`.
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:5000',
  );

  final ApiClient _apiClient;
  final String _baseUrl;
  final http.Client httpClient;

  /// Observable submission state. Listen to this to drive button/loading
  /// state and to reset out of a pending state on failure.
  final ValueNotifier<SavingsSubmissionStatus> submissionStatus =
      ValueNotifier<SavingsSubmissionStatus>(SavingsSubmissionStatus.idle);

  /// Requests an unsigned deposit XDR envelope from the backend for the
  /// given [amount] and [accountId].
  ///
  /// Domain exceptions from [ApiClient.postWithRetry] (e.g.
  /// [TransactionFailedException], [NetworkCongestedException]) are
  /// rethrown so the caller/UI controller can handle them; this keeps app
  /// state from getting stuck after a permanent failure.
  Future<String> requestDepositXdr(String amount, String accountId) async {
    try {
      final response = await _apiClient.postWithRetry(
        '$_baseUrl/api/savings/deposit',
        {'amount': amount, 'accountId': accountId},
      );

      final xdr = response['xdr'] as String? ?? response['unsignedXdr'] as String?;
      if (xdr == null || xdr.isEmpty) {
        throw const TransactionFailedException(
          'The network accepted the request but did not return a deposit XDR.',
        );
      }
      return xdr;
    } catch (e) {
      rethrow;
    }
  }

  /// Requests an unsigned withdrawal XDR envelope from the backend for the
  /// given [amount] and [accountId].
  Future<String> requestWithdrawalXdr(String amount, String accountId) async {
    try {
      final response = await _apiClient.postWithRetry(
        '$_baseUrl/api/wallet/withdraw',
        {'amount': amount, 'accountId': accountId},
      );

      final unsignedxdr = response['unsignedxdr'] as String?;
      if (unsignedxdr == null || unsignedxdr.isEmpty) {
        throw const TransactionFailedException(
          'The network accepted the request but did not return a withdrawal XDR.',
        );
      }
      return unsignedxdr;
    } catch (e) {
      rethrow;
    }
  }

  /// Submits a signed XDR envelope to the backend relay with automatic
  /// retries for transient network failures.
  Future<String> submitSignedXdr(String signedXdr) async {
    submissionStatus.value = SavingsSubmissionStatus.submitting;
    try {
      final response = await _apiClient.postWithRetry(
        '$_baseUrl/api/transactions/submit',
        {'xdr': signedXdr},
      );
      final hash = response['hash'] as String?;
      if (hash == null || hash.isEmpty) {
        throw const TransactionFailedException(
          'The network accepted the transaction but did not return a hash.',
        );
      }
      submissionStatus.value = SavingsSubmissionStatus.succeeded;
      return hash;
    } on ApiException {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      rethrow;
    } catch (error) {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      throw TransactionFailedException(
        'Failed to submit the transaction. Please try again.',
        cause: error,
      );
    }
  }

  /// Submits a signed withdrawal XDR envelope to the backend with targeted
  /// error mapping for withdrawal-specific failure conditions.
  Future<String> submitWithdrawalXdr(String signedXdr) async {
    submissionStatus.value = SavingsSubmissionStatus.submitting;
    try {
      final response = await _apiClient.postWithRetry(
        '$_baseUrl/api/transactions/submit',
        {'signedXdr': signedXdr},
      );

      final hash = response['hash'] as String?;
      if (hash == null || hash.isEmpty) {
        throw const TransactionFailedException(
          'The network accepted the withdrawal but did not return a transaction hash.',
        );
      }

      submissionStatus.value = SavingsSubmissionStatus.succeeded;
      return hash;
    } on ApiRequestException catch (error) {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      if (error.statusCode == 422) {
        throw InsufficientVaultFundsException(
          error.message,
          statusCode: error.statusCode,
          cause: error,
        );
      }
      rethrow;
    } on ApiException {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      rethrow;
    } catch (error) {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      throw TransactionFailedException(
        'Failed to submit the withdrawal transaction. Please try again.',
        cause: error,
      );
    }
  }

  /// Submits a signed trustline XDR to the backend with targeted error handling
  /// and explicit API client method.
  Future<String> submitTrustlineXdr(String signedXdr) async {
    submissionStatus.value = SavingsSubmissionStatus.submitting;
    final url = Uri.parse('$_baseUrl/api/transactions/submit');
    try {
      final response = await httpClient.post(
        url,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'signedXdr': signedXdr,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map && data.containsKey('hash')) {
          submissionStatus.value = SavingsSubmissionStatus.succeeded;
          return data['hash'] as String;
        }
        if (data is Map && data.containsKey('transactionHash')) {
          submissionStatus.value = SavingsSubmissionStatus.succeeded;
          return data['transactionHash'] as String;
        }
        submissionStatus.value = SavingsSubmissionStatus.failed;
        throw const TransactionFailedException('Transaction hash not found in successful response');
      } else {
        submissionStatus.value = SavingsSubmissionStatus.failed;
        final bodyData = jsonDecode(response.body);
        final errorMessage = bodyData is Map ? (bodyData['detail'] ?? bodyData['message'] ?? 'Unknown error') : 'Unknown error';

        if (errorMessage.toString().contains('trustline') || errorMessage.toString().contains('op_low_reserve') || errorMessage.toString().contains('op_already_exists')) {
          throw TransactionFailedException('Trustline activation error: $errorMessage', statusCode: response.statusCode);
        }
        throw TransactionFailedException('Failed to submit trustline XDR: $errorMessage', statusCode: response.statusCode);
      }
    } on ApiException {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      rethrow;
    } catch (e) {
      submissionStatus.value = SavingsSubmissionStatus.failed;
      if (e is TransactionFailedException) {
        rethrow;
      }
      throw TransactionFailedException('Network or parsing error during trustline XDR submission: $e');
    }
  }

  /// Reverts the submission state to idle so the user can attempt the action again.
  void resetSubmissionState() {
    submissionStatus.value = SavingsSubmissionStatus.idle;
  }

  /// Registers a newly generated Stellar public key with the backend.
  Future<void> registerStellarAddress(String stellarAddress) async {
    if (stellarAddress.trim().isEmpty) {
      throw ArgumentError.value(stellarAddress, 'stellarAddress', 'Cannot be empty.');
    }

    await _apiClient.postWithRetry(
      '$_baseUrl/api/wallet/register',
      {'stellarAddress': stellarAddress},
    );
  }

  Future<SavingsDataModel> fetchSavingsDashboardData(String accountId) async {
    return SavingsDataModel(balance: '0.0', apy: '0.0');
  }
}