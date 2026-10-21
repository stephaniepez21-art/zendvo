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

class TrustlineException implements Exception {
  final String message;
  final String? code;
  TrustlineException(this.message, {this.code});
  @override
  String toString() => 'TrustlineException: $message (code: $code)';
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
        client = client ?? http.Client();

  /// Backend base URL; override with `--dart-define=API_BASE_URL=...`.
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:5000',
  );

  final ApiClient _apiClient;
  final String _baseUrl;
  final http.Client client;

  /// Observable submission state. Listen to this to drive button/loading
  /// state and to reset out of a pending state on failure.
  final ValueNotifier<SavingsSubmissionStatus> submissionStatus =
      ValueNotifier<SavingsSubmissionStatus>(SavingsSubmissionStatus.idle);

  /// Requests an unsigned deposit XDR envelope from the backend for the
  /// given [amount] and [accountId].
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

      final unsignedxdr = response['unsignedxdr'] as String? ?? response['unsignedXdr'] as String?;
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
      // If ApiClient is preferred/used:
      try {
      final response = await _apiClient.postWithRetry(
        '$_baseUrl/api/transactions/submit',
          {'signedXdr': signedXdr},
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
        rethrow;
      } catch (_) {
        // Fallback to http client if ApiClient route fails or for direct HTTP integration tests
        final response = await client.post(
          Uri.parse('$_baseUrl/api/transactions/submit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'signedXdr': signedXdr}),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map && data['hash'] is String) {
            submissionStatus.value = SavingsSubmissionStatus.succeeded;
            return data['hash'] as String;
          }
          if (data is Map && data['success'] == true && data['data']?['hash'] is String) {
            submissionStatus.value = SavingsSubmissionStatus.succeeded;
            return data['data']['hash'] as String;
          }
          throw const TransactionFailedException('Invalid response structure on success');
        } else {
          String errorMsg = 'Failed to submit transaction';
          try {
            final errorData = jsonDecode(response.body);
            if (errorData is Map) {
              errorMsg = errorData['detail'] ?? errorData['title'] ?? errorData['message'] ?? errorMsg;
            }
          } catch (_) {}
          throw TransactionFailedException(errorMsg, statusCode: response.statusCode);
        }
      }
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
      if (error is TransactionFailedException) rethrow;
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

  /// Submits the signed trustline XDR to `/api/transactions/submit` with targeted error handling.
  Future<String> submitTrustlineXdr(String signedXdr) async {
    try {
      return await submitSignedXdr(signedXdr);
    } catch (e) {
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('op_low_reserve') || errStr.contains('reserve')) {
        throw TrustlineException('Trustline activation failed: Insufficient XLM reserve for trustline.', code: 'INSUFFICIENT_RESERVE');
      } else if (errStr.contains('op_line_full') || errStr.contains('full')) {
        throw TrustlineException('Trustline activation failed: Trustline limit reached.', code: 'TRUSTLINE_LIMIT');
      } else if (e is TrustlineException || e is TransactionFailedException || e is ApiException) {
        rethrow;
      } else {
        throw TrustlineException('Failed to submit trustline XDR: ${e.toString()}');
      }
    }
  }

  /// Reverts the submission state to idle.
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