package site.ycsb.db;

import org.apache.commons.io.output.NullOutputStream;
import org.apache.curator.shaded.com.google.common.io.ByteStreams;
import org.apache.iceberg.CatalogProperties;
import org.apache.iceberg.azure.AzureProperties;
import org.apache.iceberg.azure.adlsv2.AzureSAS;
import org.apache.iceberg.io.AtomicOutputFile;
import org.apache.iceberg.io.CAS;
import org.apache.iceberg.io.InputFile;
import org.apache.iceberg.io.SupportsAtomicOperations;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.Random;
import java.util.Set;
import java.util.Vector;
import java.util.concurrent.TimeUnit;

import static java.util.concurrent.TimeUnit.NANOSECONDS;

public class FileIOClient extends DB {

  private static final Logger logger = LoggerFactory.getLogger(FileIOClient.class);

  static final String FILEIO_STORE = "fileio.store";
  static final String MAX_ATTEMPTS = "fileio.max.attempts";
  static final String FILE_SIZE = "fileio.file.size";
  static final String MAX_LOG_SIZE = "fileio.max.log.size";
  static final String DELTA_SIZE = "fileio.delta.size";
  static final String FILE_NAME = "fileio.file.name";
  static final String TEST_RUN = "fileio.test.run"; // common across separate JVMs in the same test run
  static final String DEBUG_THREADS = "fileio.debug.threads"; // separate object per thread
  static final String YCSB_BACKOFF = "fileio.ycsb.backoff"; // separate object per thread
  static final String ACCOUNT_KEY_PATH = "fileio.key.path";

  private static boolean inited = false;

  String sacriFile;
  int baseSize;
  int deltaSize;
  int maxFileSize;
  int maxAttempts;
  SupportsAtomicOperations fileIO;
  byte[] replScratch;
  byte[] deltaScratch;
  final Random rand = new Random();
  boolean ycsbBackoff;


  @Override
  public void init() throws DBException {
    baseSize = Integer.parseInt(getProperties().getOrDefault(FILE_SIZE, Integer.toString(1 << 14)).toString());
    System.out.println("baseSize: " + baseSize);
    maxFileSize = baseSize + Integer.parseInt(getProperties().getOrDefault(MAX_LOG_SIZE, Integer.toString(1 << 24)).toString());
    System.out.println("maxFileSize: " + maxFileSize);
    deltaSize = Integer.parseInt(getProperties().getOrDefault(DELTA_SIZE, Integer.toString(1 << 8)).toString());
    System.out.println("deltaSize: " + deltaSize);
    maxAttempts = Integer.parseInt(getProperties().getOrDefault(MAX_ATTEMPTS, Integer.toString(10)).toString());
    System.out.println("maxAttempts: " + maxAttempts);
    replScratch = new byte[baseSize];
    deltaScratch = new byte[deltaSize];
    String bucket = getProperties().getOrDefault(FileIOCatalogClient.BUCKET_NAME, CatalogClient.YCSB_BUCKET).toString();
    boolean debugThread = Boolean.parseBoolean(getProperties().getOrDefault(DEBUG_THREADS, "false").toString());
    ycsbBackoff = Boolean.parseBoolean(getProperties().getOrDefault(YCSB_BACKOFF, "true").toString());
    System.out.println("ycsbBackoff: " + ycsbBackoff);
    final String testRun = getProperties().getOrDefault(TEST_RUN, FileIOCatalogClient.UNIQ_RUN).toString();
    System.out.println("testRun: " + testRun);
    try {
      final Map<String, String> properties = new HashMap<>();
      if (getProperties().containsKey(ACCOUNT_KEY_PATH)) {
        String saskey = getProperties().get(ACCOUNT_KEY_PATH).toString();
        if (!saskey.equals("NONE")) {
          System.out.println("saskey: " + saskey);
          properties.put("azure.creds", saskey);
        }
      }
      properties.put(TEST_RUN, testRun);
      Object o = getProperties().get(FILEIO_STORE);
      if ("aws".equals(o)) {
        // TODO hack for testing, plumb this correctly
        // bucket = "lst-pbafvfgrapl--usw2-az3--x-s3"; // s3 express bucket
        fileIO = FileIOCatalogClient.s3FileIO(bucket, properties);
        System.out.println("### S3 DIRECT ###");
      } else if ("gcp".equals(o)) {
        fileIO = FileIOCatalogClient.gcsFileIO(bucket, properties);
        maxFileSize = 0; // force CAS
        System.out.println("### GCS DIRECT ###");
      } else if ("azure".equals(o)) {
        fileIO = FileIOCatalogClient.azureFileIO(bucket, properties);
        System.out.println("### AZURE DIRECT ###");
      } else {
        throw new IllegalArgumentException("Unknown fileio object: " + getProperties().get(FILEIO_STORE));
      }
      System.out.println("bucket: " + bucket);
      sacriFile = getProperties().getOrDefault(FILE_NAME,
          properties.get(CatalogProperties.WAREHOUSE_LOCATION) + "/" + "sacriFile").toString();
      if (debugThread) {
        sacriFile += "-" + Thread.currentThread().getId();
      }
      System.out.println("### " + sacriFile + " ###");
      System.out.println("CLOCK," + System.currentTimeMillis() + "," + System.nanoTime());
      synchronized (FileIOClient.class) {
        if (!inited || debugThread) {
          InputFile in = fileIO.newInputFile(sacriFile);
          if (!in.exists()) {
            try {
              AtomicOutputFile out = fileIO.newOutputFile(in);
              rand.nextBytes(replScratch);
              atomicOp(out, replScratch, AtomicOutputFile.Strategy.CAS);
              System.out.println("Created: " + sacriFile);
            } catch (SupportsAtomicOperations.CASException e) {
              // ignore
            }
          }
          inited = true;
        }
      }
    } catch (Exception e) {
      throw new DBException("Failed to load remote / init storage", e);
    }
  }

  @Override
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result) {
    InputFile in = fileIO.newInputFile(sacriFile);
    try (InputStream i = in.newStream();
         NullOutputStream n = NullOutputStream.NULL_OUTPUT_STREAM) {
      ByteStreams.copy(i, n);
    } catch (IOException e) {
      return Status.ERROR;
    }
    return Status.OK;
  }

  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields, Vector<HashMap<String, ByteIterator>> result) {
    return Status.NOT_IMPLEMENTED;
  }

  // from BaseTransaction
  // default 4 retries
  //           .exponentialBackoff(
  //              base.propertyAsInt(COMMIT_MIN_RETRY_WAIT_MS, COMMIT_MIN_RETRY_WAIT_MS_DEFAULT), // 100
  //              base.propertyAsInt(COMMIT_MAX_RETRY_WAIT_MS, COMMIT_MAX_RETRY_WAIT_MS_DEFAULT), // 60000 (1 min)
  //              base.propertyAsInt(COMMIT_TOTAL_RETRY_TIME_MS, COMMIT_TOTAL_RETRY_TIME_MS_DEFAULT), // 30 minutes
  //              2.0 /* exponential */) // scaleFactor

  // from Tasks
  //           int delayMs =
  //              (int) Math.min(minSleepTimeMs * Math.pow(scaleFactor, attempt - 1), maxSleepTimeMs);
  //          int jitter = ThreadLocalRandom.current().nextInt(Math.max(1, (int) (delayMs * 0.1)));

  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    int attempts = 0;
    rand.nextBytes(deltaScratch);
    while (attempts++ < maxAttempts) {
      logger.trace("update table: {}, key: {}", table, key);
      InputFile in = fileIO.newInputFile(sacriFile);
      // long startCAS = -1; // DEBUG
      try {
        final long len = in.getLength();
        if (len < baseSize) {
          // !#! Azure reporting incorrect length
          if (len != 0) {
            System.out.println("INTEGRITY ERROR len: " + len);
          }
          return Status.UNEXPECTED_STATE;
        }
        if (len + deltaSize > maxFileSize) {
          // CAS TODO: Azure does not always report the correct length?
          // startCAS = System.nanoTime();
          // System.out.println("CAS0 " + System.currentTimeMillis());
          rand.nextBytes(replScratch);
          readObject(in); // read file to merge
          // System.out.println("CAS1 " + NANOSECONDS.toMillis(System.nanoTime() - startCAS));
          AtomicOutputFile out = fileIO.newOutputFile(in);
          // System.out.println("CAS2 " + NANOSECONDS.toMillis(System.nanoTime() - startCAS));
          atomicOp(out, replScratch, AtomicOutputFile.Strategy.CAS);
          // System.out.println("CAS3 " + NANOSECONDS.toMillis(System.nanoTime() - startCAS));
          return Status.OK_CAS;
        }
        // APPEND
        AtomicOutputFile out = fileIO.newOutputFile(in);
        atomicOp(out, deltaScratch, AtomicOutputFile.Strategy.APPEND);
        return Status.OK;
      } catch (SupportsAtomicOperations.CASException e) {
        maybeBackoff(attempts);
        // DEBUG
        // System.out.println("CAS4 " + NANOSECONDS.toMillis(System.nanoTime() - startCAS));
        if (e.getMessage().contains("Rate limit exceeded")) {
          // Rough estimate for GCP
          return Status.RATE_EXCEEDED;
        }
      } catch (SupportsAtomicOperations.AppendException e) {
        maybeBackoff(attempts);
      } catch (Exception e) {
          if (e.getMessage().contains("No such object:")) {
            // GCP throwing these often enough that it's annoying
            return Status.NOT_FOUND;
          }
          e.printStackTrace(System.out);
          return Status.ERROR;
      }
    }
    return Status.SERVICE_UNAVAILABLE;
  }

  private void maybeBackoff(int attempts) {
    if (ycsbBackoff) {
      int delayMs = (int) Math.min(100 * Math.pow(2.0, attempts - 1), 60000);
      int jitter = rand.nextInt(Math.max(1, (int) (delayMs * 0.1)));
      logger.info("Backing off for {} ms", delayMs + jitter);
      try {
        TimeUnit.MILLISECONDS.sleep(delayMs + jitter);
      } catch (InterruptedException ignored) {
        Thread.currentThread().interrupt();
      }
    }
  }

  private void readObject(InputFile in) throws IOException {
    try (InputStream i = in.newStream();
         NullOutputStream os = NullOutputStream.NULL_OUTPUT_STREAM) {
      ByteStreams.copy(i, os);
    }
  }

  private void atomicOp(AtomicOutputFile out, byte[] data, AtomicOutputFile.Strategy strategy) throws IOException {
    try (ByteArrayInputStream b = new ByteArrayInputStream(data)) {
      b.mark(data.length);
      CAS tok = out.prepare(() -> b, strategy);
      b.reset();
      out.writeAtomic(tok, () -> b);
    }
  }

  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values) {
    return Status.NOT_IMPLEMENTED;
  }

  @Override
  public Status delete(String table, String key) {
    logger.trace("delete table: {}, key: {}", table, key);
    return Status.NOT_IMPLEMENTED;
  }
}
